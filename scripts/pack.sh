#!/bin/bash
# Builds the release binary and packs it into a .mcpb Claude extension bundle.
#
# An .mcpb is a zip with manifest.json at its root. There is no dependency on the
# `mcpb` CLI here: zip is enough, and it keeps the toolchain to what macOS ships.
set -euo pipefail

NAME="indexa-capital-mcp"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Universal, so the bundle also runs on an Intel Mac. Go has no single-invocation
# universal build the way `swift build --arch X --arch Y` does, so each architecture
# is built separately and joined with lipo. The module-less build (no go.mod) needs
# the source file named explicitly, same as `go build main.go` in the README.
echo "==> Building $NAME (universal)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
GOOS=darwin GOARCH=arm64 go build -o "$WORK/$NAME-arm64" main.go
GOOS=darwin GOARCH=amd64 go build -o "$WORK/$NAME-amd64" main.go
lipo -create -output "$WORK/$NAME" "$WORK/$NAME-arm64" "$WORK/$NAME-amd64"

echo "==> Staging bundle"
STAGE="$ROOT/extension"
rm -rf "$STAGE/server"
mkdir -p "$STAGE/server"
cp "$WORK/$NAME" "$STAGE/server/$NAME"
chmod +x "$STAGE/server/$NAME"

# There is no TCC identity to establish here and no embedded Info.plist: this server
# reads one Keychain item by service and account name — no framework, no permission
# dialog — and sends no Apple event to anything. The signature below is about
# Gatekeeper, not permissions: an unsigned binary is killed outright on Apple
# Silicon, so even an ad-hoc signature is required just to run at all.
# MCPB_SIGN_IDENTITY is only needed for something meant to be handed to another
# machine.
IDENTITY="${MCPB_SIGN_IDENTITY:--}"
echo "==> Signing with identity: $IDENTITY"
codesign --force --identifier "codes.eneko.$NAME" --sign "$IDENTITY" "$STAGE/server/$NAME"
codesign -dv "$STAGE/server/$NAME" 2>&1 | grep -oE 'flags=[^ ]*' | sed 's/^/    /' || true

python3 -c "import json,sys; json.load(open('$STAGE/manifest.json'))" \
  || { echo "!! manifest.json is not valid JSON" >&2; exit 1; }

echo "==> Packing"
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$NAME.mcpb"
rm -f "$OUT"
# -X drops resource forks and extra attributes; the archive should contain only what
# the manifest describes.
( cd "$STAGE" && zip -qrX "$OUT" manifest.json icon.png server )

# The MCPB spec does not say whether the installer preserves the executable bit, so
# verify the archive at least records it. If a future Claude release drops it, the
# symptom is a server that never starts, and the fix is a chmod +x on the installed
# copy.
echo "==> Verifying the executable bit survived"
MODE=$(unzip -Z "$OUT" "server/$NAME" | awk 'NR==1 {print $1}')
case "$MODE" in
  *x*) echo "    mode $MODE — executable" ;;
  *)   echo "!! executable bit lost: $MODE" >&2; exit 1 ;;
esac

echo
echo "Built $OUT ($(du -h "$OUT" | cut -f1))"
echo "Install it by opening the file with Claude."
