# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Data rule

Read-only server: no tool can create, modify or delete anything. Only GET requests are made to the Indexa Capital API. Do not add a non-GET method, a caller-supplied path, or a passthrough tool.

**Tests run against fakes**: `FakeTokenSource` and `FakeTransport` (an invented token and an in-memory API), stand-in programs such as `/bin/echo` in place of `security`, and `URLProtocol` classes that answer `*.example.test` in memory. Never the owner's real accounts or real token, and never out of convenience: the suite exists to catch breaking changes and does not need real data to do that.

**Debugging against live data is legitimate, but it is the owner's call, not yours.** Never decide it alone. Ask in chat as an explicit choice they can pick, not a remark inside a longer message. Say exactly what you will run, exactly which live data it would touch, and what it would create, change or delete and whether that is undoable. A yes covers that run only; a wider or different check needs a fresh question.

Anything that runs `KeychainTokenSource()` (its default initialiser runs the real `security` lookup) or `URLSessionTransport()` against `api.indexacapital.com` touches the owner's real token and real portfolio, so it is live data and needs the ask above. There is no gentle route: the API has no sandbox and nothing to copy.

## What this is

A local MCP server (Swift 6, stdio transport) exposing four read-only tools over the Indexa Capital REST API. **No third-party dependency**: `Package.swift` lists none, networking is URLSession, the token comes from the `security` tool macOS ships, and the MCP protocol (JSON-RPC over stdio) is `MCPServer.swift` over Foundation. Adding a package needs the owner's say-so; `VersionTests` fails if one appears.

**`MCPServer.swift`, `Value.swift` and `Tests/…/MCPProtocolTests.swift` are copied unchanged into every one of the owner's MCP servers** (the test file differs only in its `@testable import`). The source of truth is `apple-system-mcp`. A change to one is made to every copy in the same piece of work; never let a copy drift.

## API

Four fixed paths on `https://api.indexacapital.com`, always `GET`, with the token in `X-AUTH-TOKEN`: `/users/me`, `/accounts/{code}`, `/accounts/{code}/portfolio`, `/accounts/{code}/performance`. `ToolCatalog.Endpoint` is the only place a path is built. Account codes must be 6 to 10 ASCII characters from `A-Z0-9` after trimming and uppercasing (`AccountCode.normalise`) before they go into a path. Redirects are refused (`RefuseRedirects`), a call times out after 20 s, and a response body is capped at 1 MiB.

The token is read on every call by running `security find-generic-password -s indexa-capital-api -a "$USER" -w`, with a 10 s limit for a locked Keychain. See [Keychain Services](https://developer.apple.com/documentation/security/keychain-services) for what that store is.

## Surface not used

- Any non-GET method, any caller-supplied path, any passthrough tool. The path table is closed by design; do not open it.
- `SecItemCopyMatching` and the rest of the Keychain Services API. The item is created by `security add-generic-password`, which puts `/usr/bin/security` on its access list. Reading it through `security` never prompts; reading it from this binary would prompt after every ad-hoc rebuild.

## Commands

```bash
swift build
swift build -c release
swift test
./scripts/pack.sh   # builds the arm64 binary and packs dist/indexa-capital-mcp.mcpb
```

## Architecture

**Apple silicon only, deliberately.** `scripts/pack.sh` builds for arm64 alone (a plain `swift build -c release`, no `--arch` flags) and fails if the binary holds any other architecture. A universal build doubles the bundle for an architecture macOS 26 is the last release to support. Do not add an x86_64 slice back.

`IndexaCapitalAPI` is the only door to the outside. It takes a `TokenSource` (`KeychainTokenSource` for real) and an `HTTPTransport` (`URLSessionTransport` for real); the tests pass doubles for both. `IndexaCapitalTools` validates the call and builds the path, and `IndexaCapitalAPI.get` does the request, the status check and the size check. Error texts in `ToolError` keep the wording the Go server had.

## Release checklist

- **Bump the version before packing.** The installer keys on the manifest `version` alone; an unchanged version under a changed build makes it offer only "Uninstall", which removes the extension.
- **Three files carry the version and must agree**: `extension/manifest.json`, `IndexaCapitalMCPServer.version` in `Server.swift`, and `CFBundleShortVersionString` in `Resources/Info.plist`. `VersionTests` and `pack.sh` both check it.
- **Installing does not restart the server.** The old process keeps answering until Claude Desktop is fully quit and reopened.
- **Never publish a bundle signed with the owner's Developer ID**: the certificate carries the owner's legal name. Pass the identity by its hash in `MCPB_SIGN_IDENTITY`, never by name, because `pack.sh` prints it.
- **The text the model reads is code.** Update the server `instructions`, tool and argument descriptions and the manifest `tools` and `long_description` in the same commit as the behaviour. `CatalogueTests` pins `tools/list` whole and checks the manifest descriptions match.

## Diagnostics

Logs go to stderr through `Diagnostics`, which the host captures (Claude Desktop writes it to `~/Library/Logs/Claude/mcp-server-<name>.log`). stdout is the JSON-RPC stream: never `print`. The API takes no free-form text on purpose. Do not add one, and do not log an argument, an account code, an API response, the token or an error's text; log a fixed event, the tool name, the error's kind and a duration.
