# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Data rule

Read-only server — no tool can create, modify, or delete anything. Only GET requests are made to the Indexa Capital API; do not add a non-GET method, a caller-supplied path, or a passthrough tool.

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
go test main.go main_test.go -live    # also calls the real API
```
