<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="indexa-capital-mcp icon">
</p>

# indexa-capital-mcp — local Indexa Capital reader (read-only)

An MCP server written in Go, **with no external dependencies** (standard library only),
that exposes 4 read-only tools against `api.indexacapital.com`. The token lives in the
macOS Keychain and never leaves your machine. It ships as a Claude extension.

Not affiliated with, endorsed by, or connected to Indexa Capital.

## Requirements

- macOS (Apple Silicon or Intel)
- Go 1.21 or later, only to build from source (`brew install go` if you don't have it)
- An Indexa Capital account and API token

## API

No Apple framework and no third-party module — Go's standard library only: `net/http`,
`encoding/json`, `os/exec`, `regexp`, `bufio`.

| Endpoint | Tool |
|---|---|
| `GET /users/me` | `indexa_capital_user` |
| `GET /accounts/{code}` | `indexa_capital_account` |
| `GET /accounts/{code}/portfolio` | `indexa_capital_portfolio` |
| `GET /accounts/{code}/performance` | `indexa_capital_performance` |

Base URL `https://api.indexacapital.com`. The path table is closed: the method is always
`GET`, account codes must match `^[A-Z0-9]{6,10}$` before interpolation, redirects are
refused, and a response is capped at 1 MiB. The token comes from the macOS Keychain by
running `security find-generic-password` — see [Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
— rather than through the Keychain C API, because one subprocess is smaller and auditable.

## Install

**1. Regenerate your token** at indexacapital.com → settings → API (the previous one
passed through your clipboard: consider it burned).

**2. Store the token in the Keychain** (it will ask you in a secure prompt — do not paste
it into the command, so it never lands in your shell history). `-U` updates the item if
it already exists, so re-running this after regenerating your token replaces it instead
of leaving two items the lookup would pick between:

```bash
security add-generic-password -s indexa-capital-api -a "$USER" -U -w
```

**3. Build the bundle:**

```bash
./scripts/pack.sh
```

That builds a universal (arm64 + Intel) binary, ad-hoc signs it — required just to run
at all on Apple Silicon, since an unsigned binary is killed by Gatekeeper outright, not a
TCC or permissions step, as there is no framework or Apple event anywhere in this server
— and writes `dist/indexa-capital-mcp.mcpb`.

**4. Install it.** Open `dist/indexa-capital-mcp.mcpb` with Claude. Then **quit Claude
Desktop completely and reopen it** — installing does not replace a server process that
is already running, and the old one keeps answering.

Ask Claude: *"call indexa_capital_user"*. It should return your data and the code of
each of your accounts. If it cannot reach the token, the error names the Keychain
service to check.

### Preparing something to distribute

```bash
MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

An ad-hoc signature (the default) is enough to run on this Mac. A real identity is only
needed for a binary meant to run on someone else's.

### Manual registration instead

```bash
go build -o indexa-capital-mcp main.go
```

```json
{
  "mcpServers": {
    "Indexa Capital": {
      "command": "/FULL/PATH/to/indexa-capital-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the same
display name collide.

## Tool switches

Plug and play: there is nothing to configure. Every one of the four tools can be turned
on and off individually in Claude Desktop, because the bundle declares them all in its
manifest.

**Reinstalling may reset the switches.** Check them after every install.

## Exposed tools

| Tool | Endpoint | What it returns |
|---|---|---|
| `indexa_capital_user` | `GET /users/me` | User and account codes |
| `indexa_capital_account` | `GET /accounts/{code}` | Account status and profile |
| `indexa_capital_portfolio` | `GET /accounts/{code}/portfolio` | Positions and valuation |
| `indexa_capital_performance` | `GET /accounts/{code}/performance` | Performance |

All four were verified against the live API on 2026-08-05.

## Tests

```bash
go test main.go main_test.go          # protocol, validation, redirect handling
go test main.go main_test.go -live    # also makes real read-only calls
```

## Why it's safe

- **Closed whitelist**: 4 fixed paths, hardcoded GET method, no passthrough of paths or
  free-form parameters (the account code is validated with `^[A-Z0-9]{6,10}$`).
- **Declared read-only**: every tool ships `readOnlyHint`/`destructiveHint` annotations, so
  the client can act on the guarantee instead of reading it in prose.
- **No inbound network**: pure stdio transport; the process listens on no port.
- **No secrets on disk or in logs**: the token lives only in the Keychain; errors return
  the HTTP status code and path, never headers.
- **Auditable**: ~290 lines, one file, zero dependencies. Read it in full before
  building — that's the whole point.

## An honest limitation

The Indexa Capital token is NOT read-only (its API accepts POSTs for contributions and
withdrawals with the same token). This server is the cage that turns it into read-only:
security depends on the token existing only in the Keychain and on nothing but this
binary using it. If you ever get suspicious, just regenerate the token.

## Licence

MIT.
