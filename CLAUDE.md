# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Data rule

Read-only server — no tool can create, modify or delete anything. Only GET requests are made to the Indexa Capital API; do not add a non-GET method, a caller-supplied path, or a passthrough tool.

**Tests run against fakes** — in-memory doubles, fixtures, data invented for the test. Never the owner's real accounts, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick — not a remark inside a longer message — saying exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

`go test -live` calls the real API with the owner's real portfolio, so it is live data and needs the ask above. There is no gentle route: the API has no sandbox and nothing to copy.

## What this is

A local MCP server (Go, stdio transport) exposing four read-only tools over the Indexa Capital REST API. One file, standard library only, no `go.mod`. The API token is read from the macOS Keychain at call time.

## Commands

```bash
go build -o indexa-capital-mcp main.go   # module-less build: the file must be named explicitly
go vet main.go
gofmt -l -w main.go
```

```bash
./scripts/pack.sh   # builds the universal binary and packs dist/indexa-capital-mcp.mcpb
```

```bash
go test main.go main_test.go          # no network, no Keychain
go test main.go main_test.go -live    # calls the real API with the owner's real accounts
```
