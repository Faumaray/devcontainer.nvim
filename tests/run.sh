#!/bin/sh
# Usage: NVIM=/path/to/nvim [OVERSEER=/path/to/overseer.nvim] tests/run.sh
# The e2e suites need root (mount namespaces), python3 and clangd; the project suite also needs
# cmake, ninja, a C++ compiler and cargo.
set -e
cd "$(dirname "$0")/.."
NVIM=${NVIM:-nvim}
"$NVIM" --headless --clean -l tests/unit.lua
if [ "$(id -u)" != 0 ] || ! command -v python3 >/dev/null; then
  echo "skipping e2e (needs root and python3)"
  exit 0
fi
if command -v clangd >/dev/null; then
  "$NVIM" --headless --clean -l tests/e2e.lua
else
  echo "skipping LSP/DAP e2e (needs clangd)"
fi
if command -v cmake >/dev/null && command -v ninja >/dev/null && command -v cargo >/dev/null; then
  "$NVIM" --headless --clean -l tests/e2e_project.lua
else
  echo "skipping project e2e (needs cmake, ninja, cargo)"
fi
