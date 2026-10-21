#!/bin/sh
# Builds the command line tool and the MCP server in release mode and links them into a bin directory (default ~/.local/bin).
#   Scripts/install.sh [bin-dir]
set -eu
cd "$(dirname "$0")/.."
BIN_DIR="${1:-$HOME/.local/bin}"
swift build -c release --product AutonomousTestingAgent --product ata-mcp
OUT="$(swift build -c release --show-bin-path)"
mkdir -p "$BIN_DIR"
ln -sf "$OUT/AutonomousTestingAgent" "$BIN_DIR/ata"
ln -sf "$OUT/ata-mcp" "$BIN_DIR/ata-mcp"
echo "Installed: $BIN_DIR/ata and $BIN_DIR/ata-mcp"
echo "Both look for the case runner next to themselves, so keep the build folder: $OUT"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) echo "Add $BIN_DIR to your PATH." ;; esac
