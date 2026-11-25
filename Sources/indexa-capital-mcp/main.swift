import IndexaCapitalMCPCore

// Launcher only. Everything testable lives in IndexaCapitalMCPCore, which the test target
// imports; an executable target cannot be imported. This server takes no settings.
await IndexaCapitalMCPServer.run()
