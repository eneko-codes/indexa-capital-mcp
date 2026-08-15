# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A local MCP server (Go, stdio transport) exposing four read-only tools over the Indexa
Capital REST API. One file, standard library only, no `go.mod`.

## Commands

```bash
go build -o indexa-capital-mcp main.go   # module-less build: the file must be named explicitly
go vet main.go
gofmt -l -w main.go                      # the tools map is column-aligned; renaming keys needs a reformat
```

```bash
./scripts/pack.sh   # builds the universal binary and packs dist/indexa-capital-mcp.mcpb
```

```bash
go test main.go main_test.go          # no network, no Keychain
go test main.go main_test.go -live    # also calls the real API
```

Both files must be named: `go test .` needs a module, but the explicit-file form works
without one, exactly as `go build main.go` does. `go vet main.go main_test.go` likewise —
vetting `main.go` alone silently skips the tests.

`TestMain` builds its own binary into a temp dir, so the out-of-process tests never run
against a stale binary in the working tree. `-live` reads the Keychain and calls the API;
it asserts on shape only and never prints account contents.

The server can also be exercised by hand, one JSON object per line:

```bash
# Protocol only, no token or network needed
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
              '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | ./indexa-capital-mcp

# One live call (reads the Keychain, hits the API)
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"indexa_capital_user","arguments":{}}}' \
  | ./indexa-capital-mcp
```

Tools needing an account take `{"account":"<code>"}` in `arguments`; get a real code from
`indexa_capital_user` first. Requests without an `id` are notifications and produce no
response — a test harness that reads one line per request will desynchronise on them.

## Credential coupling

The token is read at call time from the macOS Keychain, matched on the `keychainService`
constant (currently `indexa-capital-api`) **and** on `$USER` as the account name — a generic
password is keyed by both, so matching on service alone would pick arbitrarily between two
items. Both halves are bound to an item that already exists on the machine; changing either
breaks every call until the item is re-created with
`security add-generic-password -s <name> -a "$USER" -U -w`.

Check presence without reading the value:

```bash
security find-generic-password -s indexa-capital-api -a "$USER" >/dev/null 2>&1 && echo present
```

All four endpoints were verified working against the live API on 2026-08-05.

## Architecture

`main.go` is a JSON-RPC 2.0 loop over stdin/stdout implementing five methods
(`initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`). Everything
else returns `-32601`.

**The `tools` map is the entire authorization surface.** Each entry is a tool name mapped to
a path template, a flag for whether it needs an account code, a display title and a
description. `tools/list` is generated from it and `tools/call` dispatches through it, so
adding an endpoint means adding one map entry and nothing else — and equally, the map is the
only thing standing between the model and the rest of the API.

Two pieces of metadata sit outside that map on purpose. `toolAnnotations` is one shared value
rather than a per-entry field, because read-only is a property of the whole server: a per-tool
field could claim `readOnlyHint` on an entry the whitelist does not make read-only. And
`serverInstructions`, returned from `initialize`, carries the account-code workflow once
instead of repeating it in every parameter description. Clients treat an unannotated tool as
write-capable and destructive, so dropping the annotations silently inverts what this server
advertises about itself.

The one interpolated value is an account code, uppercased before it is matched against
`accountRe`, so lowercase input from the model is valid. `fetch` itself validates nothing —
it takes a finished path — so it is only safe while `toolsCall` remains its sole caller.

## Invariants worth protecting

The Indexa Capital token is **not** read-only — the same credential authorises POSTs for
contributions and cash withdrawals. This server is the cage that makes it read-only, so its
security is a property of the code, not of the token. Do not, without the user explicitly
asking:

- add a non-GET method, a caller-supplied path, or a passthrough tool
- relax `accountRe` or interpolate any other caller-controlled value into a path
- call `fetch` from anywhere but `toolsCall`, which would bypass the whitelist entirely
- drop the `CheckRedirect` that refuses every redirect: Go strips only
  Authorization/Cookie/Proxy-* when a redirect crosses hosts, so `X-AUTH-TOKEN` would be
  replayed to whatever host a 30x names. The whitelist pins method and path; this pins host.
- log, print, or return the token, request headers, or anything derived from them

Error text is part of that discipline. Failures report the stage and nothing more: a Keychain
read failure names the service, an HTTP failure names the status code and path. Keeping those
two paths distinct is what makes a live failure diagnosable without touching the secret — a
401 proves the Keychain read succeeded, whereas a Keychain error proves no request was sent.

`maxPayloadBytes` caps both the request line accepted and the response body read. The body
is read one byte past the cap so an over-long response is reported rather than silently
truncated into what would look like a complete result.

stdout carries JSON-RPC only. The one thing written to stderr is a scanner failure just
before `os.Exit(1)` — exiting 0 there would be indistinguishable from a clean shutdown,
which is how a server disappears mid-session with nothing to diagnose.

## Packaging as a Claude extension

`extension/manifest.json` plus `scripts/pack.sh` produce `dist/indexa-capital-mcp.mcpb`, a
zip with `manifest.json` at its root. `server.type` is `"binary"` — no Node, no Python, just
the Go binary.

The manifest's `tools` array creates the per-tool switches in Claude Desktop and is read
before the server has ever run, so a tool renamed or reworded in `main.go`'s `tools` map and
not in the manifest leaves a switch for something that no longer matches what the server
actually does. Descriptions are copied verbatim from the `tools` map for exactly this reason
— there is one source of truth, and the manifest quotes it rather than paraphrasing it.

Unlike the Apple-framework MCP servers in sibling repositories, there is no TCC identity to
establish and no embedded `Info.plist`: this server reads one Keychain item by service and
account name and sends no Apple event to anything. `pack.sh`'s ad-hoc signature exists only
because Gatekeeper kills an unsigned binary outright on Apple Silicon — it is not a
permissions step, and `MCPB_SIGN_IDENTITY` is only needed for a binary meant to run on
another machine.

Go has no single-invocation universal build the way `swift build --arch X --arch Y` does, so
`pack.sh` builds `GOARCH=arm64` and `GOARCH=amd64` separately and joins them with `lipo`.

## Naming

The platform is **Indexa Capital**, never "Indexa". Tools are `indexa_capital_*`, the binary
and repo are `indexa-capital-mcp`, the MCP server key is `Indexa Capital` — a display label
in the client, which is why it is the one name in prose form. The only bare
"indexa" strings that are correct are the real domains `api.indexacapital.com` and
`indexacapital.com`.
