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
| `indexa_capital_performance` | read | `GET /accounts/{code}/performance` | Returns, volatility and monthly history; daily data and the projection on request |

Start with `indexa_capital_user`: the other tools take an account code it returns.
Responses are the API's own JSON, passed through unmodified, except for
`indexa_capital_performance` (below).

The endpoints are described in Indexa Capital's
[API reference](https://indexacapital.com/en/api-rest-v1). It documents JSON as the only
response format and no pagination, and none of these four endpoints takes a query
parameter, so the API always answers with everything it has.

### Performance comes back in parts

The performance endpoint answers with a row for every day since the account was opened,
plus a monthly projection, so its response grows by roughly 100,000 characters a year.
Claude Code moves a tool result over 50,000 characters out of the conversation and into a
file. Since the API cannot be asked for less, the server returns less:

| Argument | Effect |
|---|---|
| none | The summary: returns, volatility, monthly history |
| `from`, `to` (`YYYY-MM-DD`) | Adds the daily data for those days, at most 31 per call. One bound alone runs to the other end of the data |
| `projection` (`true`) | Adds the projection of expected, best and worst outcomes |

The answer is two text blocks. The first says how many days of daily data exist, which
were included, and which arguments return the rest. The second is the JSON. Members and
rows are left out whole and nothing is computed or summarised, but the JSON is written
out again: keys come back sorted and numbers in their shortest form (`10000.0` as
`10000`). A range holding more than 31 days is refused with the dates that exist.

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
  (lowercase is accepted and uppercased) before it is put into a path. The dates and the
  `projection` switch of the performance tool are checked and used on this Mac only: they
  choose what is returned and are never sent to the API.
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
- **A day counts as daily data by its shape**: a row of `portfolios` with a `date`, or an
  object whose every key is a day written `YYYYMMDD`. If the API starts sending daily
  data in another shape, that part is passed through whole until the server learns it.
- **Checked against the live API on 2026-11-25**, as version 1.1.0. The selection of
  performance data added in 1.2.0 has run against invented responses only. The API is
  Indexa Capital's and can change.

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
