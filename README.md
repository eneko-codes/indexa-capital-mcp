<p align="center">
  <img src="extension/icon.png" width="128" height="128" alt="indexa-capital-mcp icon">
</p>

# indexa-capital-mcp

A local MCP server, written in Swift with **no external dependencies**, that gives Claude
read-only access to your Indexa Capital investment accounts through
`api.indexacapital.com`. The token lives in the macOS Keychain and never leaves your machine
except in the requests to the API. It ships as a Claude extension.

Not affiliated with, endorsed by, or connected to Indexa Capital.

## Requirements

- macOS 26 or later, Apple silicon
- Swift 6.0 or later, only to build from source (it comes with Xcode or the Command Line Tools)
- An Indexa Capital account and API token

## Tools

| Tool | Kind | Endpoint | What it returns |
|---|---|---|---|
| `indexa_capital_user` | read | `GET /users/me` | The user and the code of each account |
| `indexa_capital_account` | read | `GET /accounts/{code}` | Account status and profile |
| `indexa_capital_portfolio` | read | `GET /accounts/{code}/portfolio` | Positions and valuation |
| `indexa_capital_performance` | read | `GET /accounts/{code}/performance` | Performance and evolution |

Start with `indexa_capital_user`: the other tools take an account code it returns.
Responses are the API's own JSON, passed through unmodified.

The endpoints are described in Indexa Capital's
[API reference](https://indexacapital.com/en/api-rest-v1). It documents JSON as the only
response format and no pagination, and none of these four endpoints takes a query
parameter, so each call returns everything the API has for it.

## Frameworks and APIs

No third-party package: the server is Foundation and the tools macOS ships.

| Used | For | Reference |
|---|---|---|
| Indexa Capital REST API, base URL `https://api.indexacapital.com` | Every tool, with `GET` only | [API reference](https://indexacapital.com/en/api-rest-v1) |
| `security find-generic-password` | Reading the token from the macOS Keychain | [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) |
| Foundation [`URLSession`](https://developer.apple.com/documentation/foundation/urlsession) (ephemeral, redirects refused) | The HTTPS requests | |
| Foundation [`Process`](https://developer.apple.com/documentation/foundation/process) | Running `security` | |
| Foundation `JSONDecoder`, `JSONEncoder`, `FileHandle` | The [protocol](https://modelcontextprotocol.io/specification/2025-11-25) over stdio: JSON-RPC 2.0, one message per line (`initialize`, `ping`, `tools/list`, `tools/call`) | |

The token is read by running `security` rather than through the Keychain API. The item is
created by `security` (see below), which puts that tool on its access list, so reading it
the same way never shows an access prompt, however the server binary is signed.

## The rules worth knowing before you use it

- **Closed whitelist.** Four fixed paths, a hard-coded `GET` method, and no passthrough of
  paths or free-form parameters. An account code must be 6 to 10 characters from `A-Z0-9`
  (lowercase is accepted and uppercased) before it is put into a path.
- **Declared read-only.** Every tool ships `readOnlyHint`/`destructiveHint` annotations, so
  the client can act on the guarantee instead of reading it in prose.
- **No inbound network.** Pure stdio transport; the process listens on no port.
- **No secrets on disk or in logs.** The token lives only in the Keychain. Errors give the
  HTTP status code and path, never headers or the body. Requests use an ephemeral session
  with no cookie, cache or credential store.
- **Redirects are refused.** URLSession would otherwise replay the token header to whatever
  host a redirect names. A redirect is reported as its HTTP status.
- **Bounded.** A request times out after 20 seconds, a locked Keychain after 10, and a
  response larger than 1 MiB is refused rather than cut short.

## Install

### 1. Build the bundle

```bash
./scripts/pack.sh
```

That checks the three version strings agree, builds an arm64 release binary, signs it
(ad hoc by default), checks the embedded `Info.plist`, and writes
`dist/indexa-capital-mcp.mcpb`.

### 2. Install it

Open `dist/indexa-capital-mcp.mcpb` with Claude. Then **quit Claude Desktop completely and
reopen it**: installing does not replace a server process that is already running, and the
old one keeps answering.

**Bump the version before every new bundle.** The installer keys on the manifest `version`
alone. A different build under the same version makes it conclude the extension is already
installed, and its only offer is "Uninstall", which removes it.

### 3. Store the token in the Keychain

Create (or regenerate) your token at indexacapital.com → settings → API. A token that has
passed through a clipboard, a chat or your shell history should be regenerated.

The command below asks for the token in a secure prompt. Do not paste it into the command,
so it never lands in your shell history. `-U` updates the item if it already exists, so
re-running it after regenerating your token replaces it instead of leaving two items the
lookup would pick between:

```bash
security add-generic-password -s indexa-capital-api -a "$USER" -U -w
```

Ask Claude: *"call indexa_capital_user"*. It should return your data and the code of each of
your accounts. If it cannot reach the token, the error names the Keychain service to check.

### Signing

`swift build` leaves a signature the linker generated, flagged `linker-signed`, which
carries no designated requirement. `pack.sh` re-signs the binary. By default that is
ad hoc, which is enough to run on this Mac but changes the code identity on every rebuild.
An unsigned binary is killed outright on Apple silicon, so a signature of some kind is
required just to run. It is not a permissions step: there is no framework, no Apple event
and no privacy permission anywhere in this server, and the Keychain is read by `security`,
not by this binary, so there is nothing to grant in System Settings.

To keep a stable identity:

```bash
security find-identity -v -p codesigning   # copy the 40-character hash of an Apple Development or Developer ID Application identity
MCPB_SIGN_IDENTITY="<identity hash>" ./scripts/pack.sh
```

Pass the hash, not the certificate's name: `pack.sh` prints the identity it signs with,
and the name is yours.

For something to distribute, `MCPB_HARDENED=1` adds the hardened runtime and a secure
timestamp, which notarisation requires. No entitlements are needed.

## Tool switches

Plug and play: there is nothing to configure. Every tool can be turned on and off
individually in Claude Desktop, because the bundle declares all of them in its manifest.

**Reinstalling may reset the switches.** Check them after every install.

## Manual registration instead

```bash
swift build -c release
```

```json
{
  "mcpServers": {
    "Indexa Capital": {
      "command": "/absolute/path/to/indexa-capital-mcp/.build/release/indexa-capital-mcp"
    }
  }
}
```

You lose the per-tool switches. Do not do both at once: two registrations under the same
display name collide.

## Known limits

- **The token is not read-only.** Indexa Capital's API accepts `POST` for contributions and
  withdrawals with the same token. This server is the cage that turns it into read-only:
  security depends on the token existing only in the Keychain and on nothing but this
  server using it. If you ever get suspicious, regenerate the token.
- **Responses are capped at 1 MiB, and redirects are refused.**
- **Checked against the live API on 2026-08-05**, by the earlier Go build that this Swift
  server reproduces. The API is Indexa Capital's and can change.

## Development

```bash
swift build
swift test
```

The suite needs no token and touches no account: it runs against an invented token, an
in-memory API, stand-in programs in place of `security`, and `URLProtocol` classes that
answer `*.example.test` hosts in memory. A check against the real API with your real
portfolio is a deliberate, separate step; see `CLAUDE.md`.

## Licence

MIT.
