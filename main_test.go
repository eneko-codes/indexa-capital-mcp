// Tests for indexa-capital-mcp.
//
// Run:  go test main.go main_test.go            (no network, no Keychain)
//
//	go test main.go main_test.go -live      (also calls the real API)
//
// Two layers. Most checks call into the package directly, which is why this file
// is in package main: toolsCall's validation paths are functions, not behaviours
// to be inferred from a subprocess. The rest drive a built binary over stdio,
// because framing, exit status and the scan loop only exist in a real process.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var live = flag.Bool("live", false, "also run the tests that call the real Indexa Capital API")

// Path to a binary built from the sources under test, not a stale one lying in
// the working tree.
var binaryPath string

func TestMain(m *testing.M) {
	flag.Parse()
	dir, err := os.MkdirTemp("", "indexa-capital-mcp-test")
	if err != nil {
		fmt.Fprintln(os.Stderr, "creating a temp dir:", err)
		os.Exit(1)
	}
	binaryPath = filepath.Join(dir, "indexa-capital-mcp")
	if out, err := exec.Command("go", "build", "-o", binaryPath, "main.go").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "building the server under test: %v\n%s", err, out)
		os.RemoveAll(dir)
		os.Exit(1)
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// ---------------------------------------------------------------- in-process

func TestToolsListIsSorted(t *testing.T) {
	// Go randomises map iteration, so an unsorted tools/list cannot be diffed
	// between builds to show a change was harmless.
	got := toolNames(t, toolsList())
	want := []string{
		"indexa_capital_account",
		"indexa_capital_performance",
		"indexa_capital_portfolio",
		"indexa_capital_user",
	}
	if len(got) != len(want) {
		t.Fatalf("got %d tools, want %d: %v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("position %d: got %q, want %q", i, got[i], want[i])
		}
	}
}

// A client that sees no annotations must assume a tool is write-capable,
// destructive and non-idempotent — the exact opposite of every tool here.
func TestToolsAreAnnotatedReadOnly(t *testing.T) {
	want := map[string]bool{
		"readOnlyHint":    true,
		"destructiveHint": false,
		"idempotentHint":  true,
		"openWorldHint":   true, // this server does reach an external API
	}
	for _, tool := range toolsList().(map[string]any)["tools"].([]map[string]any) {
		name := tool["name"].(string)
		annotations, ok := tool["annotations"].(map[string]any)
		if !ok {
			t.Errorf("%s: no annotations at all", name)
			continue
		}
		for hint, expected := range want {
			got, present := annotations[hint]
			if !present {
				t.Errorf("%s: %s missing", name, hint)
				continue
			}
			if got != expected {
				t.Errorf("%s: %s is %v, want %v", name, hint, got, expected)
			}
		}
	}
}

// Every one of these must be refused before fetch is reached, so none of them
// touch the Keychain or the network.
func TestToolsCallRejectsBadInput(t *testing.T) {
	cases := []struct {
		name   string
		params string
		want   string
	}{
		{"unknown tool", `{"name":"nope","arguments":{}}`, "unknown tool: nope"},
		{"malformed code", `{"name":"indexa_capital_account","arguments":{"account":"not-valid!"}}`, "invalid account code"},
		{"path traversal", `{"name":"indexa_capital_account","arguments":{"account":"../../users/me"}}`, "invalid account code"},
		{"code too short", `{"name":"indexa_capital_account","arguments":{"account":"AB12"}}`, "invalid account code"},
		{"missing account", `{"name":"indexa_capital_account","arguments":{}}`, "invalid account code"},
		// A non-string value must fail the account check, not the whole decode:
		// models routinely pass fields that are not in the schema.
		{"non-string account", `{"name":"indexa_capital_account","arguments":{"account":42}}`, "invalid account code"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, rerr := toolsCall(json.RawMessage(c.params))
			if rerr == nil {
				t.Fatalf("accepted %s", c.params)
			}
			if rerr.Message != c.want {
				t.Errorf("got %q, want %q", rerr.Message, c.want)
			}
			if rerr.Code != -32602 {
				t.Errorf("got code %d, want -32602", rerr.Code)
			}
		})
	}
}

func TestReplySkipsNotifications(t *testing.T) {
	var buf bytes.Buffer
	reply(&buf, nil, map[string]any{"ignored": true}, nil)
	if buf.Len() != 0 {
		t.Errorf("a notification drew a reply: %s", buf.String())
	}

	buf.Reset()
	reply(&buf, json.RawMessage("7"), map[string]any{"ok": true}, nil)
	// One line, newline-terminated: that framing is what the client splits on.
	if got := buf.String(); !strings.HasSuffix(got, "\n") || strings.Count(got, "\n") != 1 {
		t.Errorf("bad framing: %q", got)
	}
	var msg map[string]any
	if err := json.Unmarshal(buf.Bytes(), &msg); err != nil {
		t.Fatal(err)
	}
	if msg["jsonrpc"] != "2.0" || msg["id"].(float64) != 7 {
		t.Errorf("unexpected envelope: %v", msg)
	}
}

// The whitelist pins the method and the path. This pins the destination host,
// which is the axis a whitelist does not cover.
func TestClientDoesNotLeakTokenAcrossRedirect(t *testing.T) {
	probe := func(client *http.Client) (leaked bool, status int) {
		attacker := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Header.Get("X-AUTH-TOKEN") != "" {
				leaked = true
			}
		}))
		defer attacker.Close()
		api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, attacker.URL+"/steal", http.StatusFound)
		}))
		defer api.Close()

		req, err := http.NewRequest(http.MethodGet, api.URL+"/users/me", nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("X-AUTH-TOKEN", "NOT-A-REAL-TOKEN")
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("request failed: %v", err)
		}
		defer resp.Body.Close()
		return leaked, resp.StatusCode
	}

	// Establish that the leak is real first. Without this the test would keep
	// passing if Go ever changed its redirect behaviour, proving nothing.
	if leaked, _ := probe(&http.Client{Timeout: 5 * time.Second}); !leaked {
		t.Fatal("a default client did not forward the token, so this test proves nothing")
	}

	leaked, status := probe(newHTTPClient())
	if leaked {
		t.Error("the token crossed the redirect")
	}
	// fetch reports non-200 as "returned HTTP %d on %s"; surfacing the 302 as a
	// status is what makes a redirect diagnosable instead of a generic failure.
	if status != http.StatusFound {
		t.Errorf("got status %d, want 302 handed back to the caller", status)
	}
}

// ------------------------------------------------------------- out-of-process

type session struct {
	t   *testing.T
	in  io.WriteCloser
	out *bufio.Reader
}

func newSession(t *testing.T) *session {
	t.Helper()
	cmd := exec.Command(binaryPath)
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		in.Close()
		cmd.Wait()
	})
	return &session{t: t, in: in, out: bufio.NewReader(stdout)}
}

func (s *session) send(line string) {
	s.t.Helper()
	if _, err := io.WriteString(s.in, line+"\n"); err != nil {
		s.t.Fatalf("writing %q: %v", line, err)
	}
}

func (s *session) exchange(line string) map[string]any {
	s.t.Helper()
	s.send(line)
	raw, err := s.out.ReadString('\n')
	if err != nil {
		s.t.Fatalf("no reply to %q: %v", line, err)
	}
	var msg map[string]any
	if err := json.Unmarshal([]byte(raw), &msg); err != nil {
		s.t.Fatalf("reply to %q is not JSON: %v", line, err)
	}
	return msg
}

func (s *session) call(tool string, arguments map[string]any) map[string]any {
	s.t.Helper()
	params, err := json.Marshal(map[string]any{"name": tool, "arguments": arguments})
	if err != nil {
		s.t.Fatal(err)
	}
	return s.exchange(fmt.Sprintf(`{"jsonrpc":"2.0","id":99,"method":"tools/call","params":%s}`, params))
}

func TestHandshakeOverStdio(t *testing.T) {
	s := newSession(t)

	msg := s.exchange(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)
	result := msg["result"].(map[string]any)
	if got := result["protocolVersion"]; got != protocolVersion {
		t.Errorf("protocolVersion %v, want %v", got, protocolVersion)
	}
	if got := result["serverInfo"].(map[string]any)["name"]; got != "indexa-capital-mcp" {
		t.Errorf("serverInfo.name %v", got)
	}

	// The instructions field is the only place the account-code workflow can be
	// stated once for the whole server rather than repeated per parameter.
	instructions, _ := result["instructions"].(string)
	if instructions == "" {
		t.Error("initialize carries no instructions")
	}
	// Case-insensitive: what matters is that the fact is stated, not how it is
	// capitalised at the start of a sentence.
	lowered := strings.ToLower(instructions)
	for _, want := range []string{"indexa_capital_user", "read-only"} {
		if !strings.Contains(lowered, want) {
			t.Errorf("instructions do not mention %q", want)
		}
	}

	// A notification draws no reply. If it did, the stream would desynchronise
	// and the next read would return someone else's response.
	s.send(`{"jsonrpc":"2.0","method":"notifications/initialized"}`)

	if msg := s.exchange(`{"jsonrpc":"2.0","id":2,"method":"ping"}`); msg["id"].(float64) != 2 {
		t.Errorf("stream desynchronised after a notification: %v", msg)
	}

	msg = s.exchange(`{"jsonrpc":"2.0","id":3,"method":"resources/list"}`)
	if code := msg["error"].(map[string]any)["code"].(float64); code != -32601 {
		t.Errorf("unsupported method returned %v, want -32601", code)
	}
}

func TestMalformedLineIsAnswered(t *testing.T) {
	s := newSession(t)

	// Staying silent leaves a client that did send an id waiting forever.
	for _, line := range []string{
		"this is not json",
		`[{"jsonrpc":"2.0","id":3,"method":"tools/list"}]`, // a batch: valid JSON, wrong shape
	} {
		msg := s.exchange(line)
		if code := msg["error"].(map[string]any)["code"].(float64); code != -32700 {
			t.Errorf("%q returned %v, want -32700", line, code)
		}
		if msg["id"] != nil {
			t.Errorf("%q: id is %v, want null", line, msg["id"])
		}
	}

	// A blank line is not a request and still draws nothing.
	s.send("")
	if msg := s.exchange(`{"jsonrpc":"2.0","id":4,"method":"ping"}`); msg["id"].(float64) != 4 {
		t.Errorf("a blank line disturbed the stream: %v", msg)
	}
}

func TestOversizedLineExitsLoudly(t *testing.T) {
	// Exiting 0 here is indistinguishable from a clean shutdown, which is how a
	// server disappears mid-session with nothing to diagnose.
	cmd := exec.Command(binaryPath)
	cmd.Stdin = strings.NewReader(strings.Repeat("x", 2<<20) + "\n")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	err := cmd.Run()
	if err == nil {
		t.Fatal("exited 0 on an oversized line")
	}
	if !strings.Contains(stderr.String(), "reading stdin") {
		t.Errorf("stderr does not explain the exit: %q", stderr.String())
	}
	if strings.Contains(stderr.String(), "xxxx") {
		t.Errorf("the diagnostic echoed the offending line: %q", stderr.String())
	}
}

// -------------------------------------------------------------------- live

// Guarded by -live: it reads the Keychain and calls the real API. Assertions are
// on shape only, never on balances, and nothing here prints account contents.
func TestLiveEndpoints(t *testing.T) {
	if !*live {
		t.Skip("pass -live to call the real Indexa Capital API")
	}
	s := newSession(t)
	s.exchange(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`)

	payload := func(t *testing.T, msg map[string]any) map[string]any {
		t.Helper()
		result, ok := msg["result"].(map[string]any)
		if !ok {
			t.Fatalf("no result: %v", msg["error"])
		}
		text := result["content"].([]any)[0].(map[string]any)["text"].(string)
		if isError, _ := result["isError"].(bool); isError {
			t.Fatalf("tool reported an error: %s", text)
		}
		var decoded map[string]any
		if err := json.Unmarshal([]byte(text), &decoded); err != nil {
			t.Fatalf("response is not a JSON object: %v", err)
		}
		return decoded
	}

	user := payload(t, s.call("indexa_capital_user", map[string]any{}))
	accounts, _ := user["accounts"].([]any)
	if len(accounts) == 0 {
		t.Fatal("no accounts returned; the remaining tools need a code")
	}
	code, _ := accounts[0].(map[string]any)["account_number"].(string)
	if code == "" {
		t.Fatal("first account carries no account_number")
	}

	// Lowercase on purpose: toolsCall must uppercase before substituting into the
	// path, or accountRe rejects a code the API would have accepted.
	payload(t, s.call("indexa_capital_account", map[string]any{"account": strings.ToLower(code)}))

	// With a field outside the schema, of the kind a model may add unprompted.
	payload(t, s.call("indexa_capital_account", map[string]any{"account": code, "limit": 5}))

	for _, tool := range []string{"indexa_capital_portfolio", "indexa_capital_performance"} {
		got := payload(t, s.call(tool, map[string]any{"account": code}))
		t.Logf("%s returned %d top-level keys", tool, len(got))
	}
}

// ------------------------------------------------------------------- helpers

func toolNames(t *testing.T, listing any) []string {
	t.Helper()
	tools, ok := listing.(map[string]any)["tools"].([]map[string]any)
	if !ok {
		t.Fatalf("tools/list has an unexpected shape: %#v", listing)
	}
	names := make([]string, 0, len(tools))
	for _, tool := range tools {
		names = append(names, tool["name"].(string))
	}
	return names
}
