<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="indexa-capital-mcp icon">
</p>

# indexa-capital-mcp

A local MCP server, written in Go with **no external dependencies** (standard library only),
that gives Claude read-only access to your Indexa Capital investment accounts through
`api.indexacapital.com`. The token lives in the macOS Keychain and never leaves your machine.
It ships as a Claude extension.

Not affiliated with, endorsed by, or connected to Indexa Capital.

## Requirements

- macOS on Apple silicon
- Go 1.21 or later, only to build from source (`brew install go` if you don't have it)
- An Indexa Capital account and API token

## Tools

| Tool | Kind | Endpoint | What it returns |
|---|---|---|---|
| `indexa_capital_user` | read | `GET /users/me` | The user and the code of each account |
| `indexa_capital_account` | read | `GET /accounts/{code}` | Account status and profile |
| `indexa_capital_portfolio` | read | `GET /accounts/{code}/portfolio` | Positions and valuation |
| `indexa_capital_performance` | read | `GET /accounts/{code}/performance` | Performance and evolution |

Start with `indexa_capital_user`: the other tools take an account code it returns.

## Frameworks and APIs

No Apple framework and no third-party module — Go's standard library only: `net/http`,
`encoding/json`, `os/exec`, `regexp`, `bufio`.

| Used | For | Reference |
|---|---|---|
| Indexa Capital REST API, base URL `https://api.indexacapital.com` | Every tool, with `GET` only | The endpoints in the table above |
| `security find-generic-password` | Reading the token from the macOS Keychain | [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) |

The token is read by running `security` rather than through the Keychain C API, because one
subprocess is smaller and auditable. The path table is closed: the method is always `GET`,
account codes must match `^[A-Z0-9]{6,10}$` before interpolation, redirects are refused, and
a response is capped at 1 MiB.

## The rules worth knowing before you use it

- **Closed whitelist.** Fixed paths, a hard-coded `GET` method, and no passthrough of paths
  or free-form parameters.
- **Declared read-only.** Every tool ships `readOnlyHint`/`destructiveHint` annotations, so
  the client can act on the guarantee instead of reading it in prose.
- **No inbound network.** Pure stdio transport; the process listens on no port.
- **No secrets on disk or in logs.** The token lives only in the Keychain; errors return the
  HTTP status code and path, never headers.
- **Auditable.** One file, zero dependencies. Read it in full before building — that is the
  whole point.

## Install

### 1. Build the bundle

```bash
./scripts/pack.sh
```

That builds an arm64 binary, signs it ad hoc, and writes `dist/indexa-capital-mcp.mcpb`.

### 2. Install it

Open `dist/indexa-capital-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it** — installing does not replace a server process that is already running, and the
old one keeps answering.

### 3. Store the token in the Keychain

Create (or regenerate) your token at indexacapital.com → settings → API. A token that has
passed through a clipboard, a chat or your shell history should be regenerated.

The command below asks for the token in a secure prompt — do not paste it into the command,
so it never lands in your shell history. `-U` updates the item if it already exists, so
re-running it after regenerating your token replaces it instead of leaving two items the
lookup would pick between:

```bash
security add-generic-password -s indexa-capital-api -a "$USER" -U -w
```

Ask Claude: *"call indexa_capital_user"*. It should return your data and the code of each of
your accounts. If it cannot reach the token, the error names the Keychain service to check.

### Signing

An ad-hoc signature is required just to run at all on Apple silicon: an unsigned binary is
killed by Gatekeeper outright. It is not a permissions step — there is no framework, no
Apple event and no privacy permission anywhere in this server, so there is nothing to grant
in System Settings.

### Preparing something to distribute

```bash
MCPB_SIGN_IDENTITY="Developer ID Application: …" ./scripts/pack.sh
```

The default ad-hoc signature is enough to run on this Mac. A real identity is only needed
for a binary meant to run on someone else's.

## Tool switches

Plug and play: there is nothing to configure. Every tool can be turned on and off
individually in Claude Desktop, because the bundle declares all of them in its manifest.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

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

## Known limits

- **The token is not read-only.** Indexa Capital's API accepts `POST` for contributions and
  withdrawals with the same token. This server is the cage that turns it into read-only:
  security depends on the token existing only in the Keychain and on nothing but this binary
  using it. If you ever get suspicious, regenerate the token.
- **Responses are capped at 1 MiB, and redirects are refused.**
- **Checked against the live API on 2026-08-05.** The API is Indexa Capital's and can change.

## Development

```bash
go test main.go main_test.go          # protocol, validation, redirect handling
go test main.go main_test.go -live    # also makes real read-only calls
```

The default run needs no token and touches no account. `-live` calls the real API with your
real portfolio; run it only when you mean to.

## Licence

MIT.
