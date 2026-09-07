# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Data rule

Read-only server — no tool can create, modify, or delete anything. Only GET requests are made to the Indexa Capital API; do not add a non-GET method, a caller-supplied path, or a passthrough tool.

## HARD RULE — TESTS NEVER RUN AGAINST THE OWNER'S REAL DATA

**Every test runs against fakes: in-memory doubles, fixtures, and data invented for the
test.** Never against real data the owner created. This rule outranks every other
instruction in this file — there is no "just this once", no "it is only a read so it is
harmless", and no putting-it-back-afterwards.

That covers the whole suite, a manual run of the built binary, and any check an agent does
on its own initiative "just to see". A test that reaches the owner's real store has stopped
testing this server and started using it.

**If you believe live data is genuinely needed, stop and ask before doing anything.** The
owner can grant an exception, but only for a specific check they have seen in full. Put it
to them in chat as an explicit choice — a question with options, not a remark inside a
longer message — and state:

1. exactly what you intend to run;
2. exactly which live data it would touch, named rather than summarised;
3. what it would create, change or delete, and whether that is reversible.

Go ahead only once the owner has chosen the option that allows it. An unrelated "go ahead",
a general permission from earlier in the session, or silence is not that consent — and the
exception covers only the run that was described, not the next one.

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

`-live` reads the owner's actual portfolio, so it falls under the hard rule above: ask
first, and run it only with their explicit go-ahead.
