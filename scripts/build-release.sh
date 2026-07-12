#!/bin/bash
# Build the arm64 release binary and sanity-check it.
# usage: scripts/build-release.sh <version>
set -euo pipefail
VERSION="${1:?usage: build-release.sh <version>}"

swift build --configuration release --arch arm64
BIN="$(swift build --configuration release --arch arm64 --show-bin-path)/tokiwatari"

[[ -x "$BIN" ]] || { echo "error: binary not found or not executable: $BIN" >&2; exit 1; }
lipo -archs "$BIN" | grep -qw arm64 \
  || { echo "error: $BIN is not arm64 (got: $(lipo -archs "$BIN"))" >&2; exit 1; }
ACTUAL="$("$BIN" --version)"
[[ "$ACTUAL" == "$VERSION" ]] \
  || { echo "error: --version reports $ACTUAL, expected $VERSION" >&2; exit 1; }
"$BIN" --help > /dev/null

echo "$BIN"
