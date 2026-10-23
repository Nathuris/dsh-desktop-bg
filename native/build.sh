#!/bin/sh
# Rebuild the accessibility helper from source.
# swiftc needs a writable module cache; the plugin keeps one under .build/.
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/cache .build/tmp bin
TMPDIR="$PWD/.build/tmp" \
CLANG_MODULE_CACHE_PATH="$PWD/.build/cache" \
  swiftc -O native/axhelper.swift -o bin/axhelper
echo "built $(pwd)/bin/axhelper"
