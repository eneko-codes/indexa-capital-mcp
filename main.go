// indexa-capital-mcp: a local, READ-ONLY MCP server for the Indexa Capital API.
//
// Security by design:
//   - Go standard library only: zero supply chain.
//   - Endpoint whitelist: only GET requests to fixed paths. No passthrough.
//   - The token lives in the macOS Keychain (service "indexa-capital-api"); never
//     in files, never in logs, never in the responses.
//   - stdio transport: this process opens no network port.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"
	"time"
)

const (
	baseURL         = "https://api.indexacapital.com"
	keychainService = "indexa-capital-api"
	protocolVersion = "2024-11-05"

	// One ceiling for both directions: the longest request line accepted and the
	// most response body read. Bounds what a single call can cost in memory.
	maxPayloadBytes = 1 << 20

	httpTimeout     = 20 * time.Second
	keychainTimeout = 10 * time.Second
)

var accountRe = regexp.MustCompile(`^[A-Z0-9]{6,10}$`)

// Closed whitelist: tool name -> path template (GET method implied).
// %s is substituted with the already-validated account code. Nothing else is reachable.
var tools = map[string]struct {
	Path        string
	NeedsCode   bool
	Title       string
	Description string
}{
	"indexa_capital_user":        {"/users/me", false, "Indexa Capital user and accounts", "Authenticated user's data and the list of their accounts (codes)"},
	"indexa_capital_account":     {"/accounts/%s", true, "Indexa Capital account details", "Basic information for an account (status, risk profile)"},
	"indexa_capital_portfolio":   {"/accounts/%s/portfolio", true, "Indexa Capital portfolio", "Current portfolio: positions and valuation"},
	"indexa_capital_performance": {"/accounts/%s/performance", true, "Indexa Capital performance", "Account performance and evolution"},
}

// One shared value rather than a per-entry field: every tool is a fixed GET, so
// these describe the server, not any one entry. A per-tool field could be set to
// readOnlyHint:true on an entry the whitelist does not actually make read-only;
// this cannot. Clients treat a tool with no annotations as write-capable,
// destructive and non-idempotent, which is the opposite of what this server is.
var toolAnnotations = map[string]any{
	"readOnlyHint":    true,  // nothing reachable here can modify an account
	"destructiveHint": false, // implied by readOnlyHint, stated for clients that read it directly
	"idempotentHint":  true,  // repeating a GET changes nothing
	"openWorldHint":   true,  // the data comes from an external API, not a fixed set
}

// Free-text guidance carried in the initialize result. It exists to state the
// two things the per-tool metadata cannot: that the account code has to be
// fetched before the account-scoped tools are usable, and that the read-only
// guarantee is a property of this server rather than of the credential.
const serverInstructions = `Read-only access to Indexa Capital investment accounts.

Every tool is a fixed GET request. Nothing exposed here can move money, make a
contribution, or change an account in any way.

The account-scoped tools need an account code. Call indexa_capital_user first:
it returns the authenticated user together with the code of every account they
hold. Pass one of those codes to the other tools. Codes are 6-10 uppercase
alphanumeric characters; lowercase input is accepted and normalised.

Responses are the API's own JSON, passed through unmodified.`

// Decode-only; replies are assembled as maps in reply(). A request carrying no
// "id" leaves ID nil, which is how a notification is recognised.
type rpcRequest struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func reply(w io.Writer, id json.RawMessage, result any, rerr *rpcError) {
	if id == nil {
		return // notification: no response
	}
	msg := map[string]any{"jsonrpc": "2.0", "id": id}
	if rerr != nil {
		msg["error"] = rerr
	} else {
		msg["result"] = result
	}
	json.NewEncoder(w).Encode(msg) // Encode appends the newline that frames the message
}

// Matches on service AND account because a generic password is keyed by both:
// looking up on service alone would pick arbitrarily between two items created
// under different account names. The account must be the one the README's
// add-generic-password command uses, i.e. $USER.
func tokenFromKeychain() (string, error) {
	// A locked Keychain makes `security` block on a GUI unlock prompt. Without a
	// deadline that stalls the whole serial loop, not just this call, and the
	// client sees an unexplained hang instead of an error it can report.
	ctx, cancel := context.WithTimeout(context.Background(), keychainTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "security", "find-generic-password",
		"-s", keychainService, "-a", os.Getenv("USER"), "-w").Output()
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("timed out reading the token from the Keychain (service %q); is the Keychain locked?", keychainService)
	}
	if err != nil {
		return "", fmt.Errorf("could not read the token from the Keychain (service %q)", keychainService)
	}
	return strings.TrimSpace(string(out)), nil
}

// Redirects are refused rather than followed: Go strips only
// Authorization/Cookie/Proxy-* when a redirect crosses hosts, so X-AUTH-TOKEN would
// be replayed to whatever host a 30x names. The whitelist pins the method and the
// path; this pins the destination.
func newHTTPClient() *http.Client {
	return &http.Client{
		Timeout: httpTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// The caller MUST build path from the tools whitelist: fetch validates nothing,
// so a second call site passing a path of its own would be a hole in the cage.
func fetch(path string) (string, error) {
	token, err := tokenFromKeychain()
	if err != nil {
		return "", err
	}
	client := newHTTPClient()
	req, err := http.NewRequest(http.MethodGet, baseURL+path, nil) // always a fixed GET
	if err != nil {
		return "", fmt.Errorf("internal error building the request")
	}
	req.Header.Set("X-AUTH-TOKEN", token)
	req.Header.Set("Accept", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("network error reaching the Indexa Capital API")
	}
	defer resp.Body.Close()
	// One byte past the cap, so a body that would be truncated is detected instead
	// of being handed to the model as though it were complete.
	body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxPayloadBytes+1))
	if resp.StatusCode != http.StatusOK {
		// We never include headers or the token in the error, only the status code.
		// A redirect lands here too, since CheckRedirect refuses to follow it.
		return "", fmt.Errorf("the Indexa Capital API returned HTTP %d on %s", resp.StatusCode, path)
	}
	if readErr != nil {
		return "", fmt.Errorf("could not read the response body from %s", path)
	}
	if len(body) > maxPayloadBytes {
		return "", fmt.Errorf("the response from %s exceeds the %d byte limit", path, maxPayloadBytes)
	}
	return string(body), nil
}

func toolsList() any {
	list := []map[string]any{}
	// Sorted: Go randomises map iteration, and an unstable tools/list cannot be
	// diffed between builds to show a change was harmless.
	for _, name := range slices.Sorted(maps.Keys(tools)) {
		t := tools[name]
		schema := map[string]any{"type": "object", "properties": map[string]any{}, "required": []string{}}
		if t.NeedsCode {
			schema["properties"] = map[string]any{
				"account": map[string]any{
					"type":        "string",
					"description": "Indexa Capital account code (e.g. ABCD1234), obtainable via indexa_capital_user",
				},
			}
			schema["required"] = []string{"account"}
		}
		list = append(list, map[string]any{
			"name":        name,
			"title":       t.Title,
			"description": t.Description,
			"inputSchema": schema,
			// Read-only is declared here rather than narrated in the description:
			// a client can act on a field, but not on an adjective in prose.
			"annotations": toolAnnotations,
		})
	}
	return map[string]any{"tools": list}
}

func toolsCall(params json.RawMessage) (any, *rpcError) {
	var p struct {
		Name string `json:"name"`
		// any, not string: models routinely add fields outside the schema, and one
		// stray number must not fail the whole decode before validation is reached.
		Arguments map[string]any `json:"arguments"`
	}
	if err := json.Unmarshal(params, &p); err != nil {
		return nil, &rpcError{-32602, "invalid parameters"}
	}
	t, ok := tools[p.Name]
	if !ok {
		return nil, &rpcError{-32602, "unknown tool: " + p.Name}
	}
	path := t.Path
	if t.NeedsCode {
		account, _ := p.Arguments["account"].(string) // non-string fails the regex below
		code := strings.ToUpper(strings.TrimSpace(account))
		if !accountRe.MatchString(code) {
			return nil, &rpcError{-32602, "invalid account code"}
		}
		path = fmt.Sprintf(t.Path, code)
	}
	body, err := fetch(path)
	if err != nil {
		return map[string]any{
			"content": []map[string]any{{"type": "text", "text": "Error: " + err.Error()}},
			"isError": true,
		}, nil
	}
	return map[string]any{
		"content": []map[string]any{{"type": "text", "text": body}},
	}, nil
}

func main() {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 0, maxPayloadBytes), maxPayloadBytes)
	out := os.Stdout

	for in.Scan() {
		line := strings.TrimSpace(in.Text())
		if line == "" {
			continue
		}
		var req rpcRequest
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			// The id is unknowable once parsing failed, so the spec's null id is all
			// we can answer with — but staying silent leaves a client that did send
			// an id waiting for a reply that never comes.
			reply(out, json.RawMessage("null"), nil, &rpcError{-32700, "parse error"})
			continue
		}
		switch req.Method {
		case "initialize":
			reply(out, req.ID, map[string]any{
				"protocolVersion": protocolVersion,
				"capabilities":    map[string]any{"tools": map[string]any{}},
				"serverInfo":      map[string]any{"name": "indexa-capital-mcp", "version": "1.0.0"},
				"instructions":    serverInstructions,
			}, nil)
		case "notifications/initialized":
			// no response
		case "ping":
			reply(out, req.ID, map[string]any{}, nil)
		case "tools/list":
			reply(out, req.ID, toolsList(), nil)
		case "tools/call":
			res, rerr := toolsCall(req.Params)
			reply(out, req.ID, res, rerr)
		default:
			reply(out, req.ID, nil, &rpcError{-32601, "unsupported method: " + req.Method})
		}
	}
	// Scan() also returns false on error — an oversized line, a failed read. Exiting
	// 0 there is indistinguishable from a clean shutdown, which is how the server
	// disappears mid-session with nothing to diagnose. Scanner faults carry no
	// request content, so stderr is safe.
	if err := in.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "indexa-capital-mcp: reading stdin: %v\n", err)
		os.Exit(1)
	}
}
