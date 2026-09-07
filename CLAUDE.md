# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Data rule

Read-only server — no tool can create, modify, or delete anything. Only GET requests are made to the Indexa Capital API; do not add a non-GET method, a caller-supplied path, or a passthrough tool.

## HARD RULE — LIVE DATA IS THE OWNER'S CALL, NOT YOURS

**By default, tests run against fakes**: in-memory doubles, fixtures, and data invented for
the test. That is what makes the suite repeatable and safe to run unattended. An automated
test exists to catch a breaking change, and it does not need the owner's real data to do
that — so never reach for the real thing out of convenience.

**Debugging is different.** Sometimes the only way to see a real bug is against real data,
and that is a legitimate thing to do here — this rule is not a blanket ban and must not be
read as one. What is forbidden is deciding it alone. However harmless the check looks, the
owner decides whether their own data is touched.

So ask, before doing anything: put an explicit choice to the owner in chat — a question
with options they can pick, not a remark buried in a longer message — stating

1. exactly what you intend to run;
2. exactly which live data it would touch, named rather than summarised;
3. what it would create, change or delete, and whether that is reversible.

If they pick the option that allows it, go ahead and do it. That is a real yes. The
permission covers the run you described — a different check, or a wider one, means a fresh
question. An unrelated "go ahead" earlier in the session is not that consent.

**A yes is not permission to be careless.** Once allowed, still pick the gentlest way to get
the answer. Work down this ladder and stop at the first rung that settles the question:

1. read, and write nothing;
2. create your own record and act on that — make a new one, then modify or delete *that*,
   never something the owner made;
3. ask the owner to create a throwaway record for you to work on, saying what it needs to
   look like;
4. work on a copy of the real data, off to one side.

Changing or deleting something the owner created is the last resort. It has to have been
named in the question you asked, it has to have a way back, and you have to say which rung
you are on and why the gentler ones cannot answer it. Whatever you created, remove in the
same session.

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
