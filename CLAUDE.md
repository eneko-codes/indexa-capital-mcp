# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Data rule

Read-only server — no tool can create, modify or delete anything. Only GET requests are made to the Indexa Capital API; do not add a non-GET method, a caller-supplied path, or a passthrough tool.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real accounts, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

`go test -live` calls the real API with the owner's real portfolio, so it is live data and needs the ask above. There is no gentle route: the API has no sandbox and nothing to copy.

## What this is

A local MCP server (Go, stdio transport) exposing four read-only tools over the Indexa Capital REST API. One file, standard library only, no `go.mod`. The API token is read from the macOS Keychain at call time.

## API

No Apple framework and no third-party module: Go's standard library only — `net/http`, `encoding/json`, `os/exec`, `regexp`, `bufio`. The token is read from the Keychain by running `security find-generic-password`; see [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) for what that store is.

Four fixed paths on `https://api.indexacapital.com`, always `GET`: `/users/me`, `/accounts/{code}`, `/accounts/{code}/portfolio`, `/accounts/{code}/performance`. Account codes are validated against `^[A-Z0-9]{6,10}$` before interpolation, redirects are refused, and the response is capped at 1 MiB.

## Surface not used

- Any non-GET method, any caller-supplied path, any passthrough tool. The path table is closed by design; do not open it.
- The Keychain Services C API — one `security` subprocess is smaller and auditable.

## Commands

```bash
go build -o indexa-capital-mcp main.go   # module-less build: the file must be named explicitly
go vet main.go
gofmt -l -w main.go
```

```bash
./scripts/pack.sh   # builds the arm64 binary and packs dist/indexa-capital-mcp.mcpb
```

```bash
go test main.go main_test.go          # no network, no Keychain
go test main.go main_test.go -live    # calls the real API with the owner's real accounts
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone (`GOARCH=arm64`, no `lipo`) and fails if the binary
holds any other architecture. A universal build doubles the bundle for an architecture
macOS 26 is the last release to support. Do not add an x86_64 slice back.
