#!/bin/bash
# Assemble the arm64 distribution archive.
# usage: scripts/package-release.sh <version> [output-dir]
set -euo pipefail
VERSION="${1:?usage: package-release.sh <version> [output-dir]}"
OUT="${2:-dist}"

BIN="$(swift build --configuration release --arch arm64 --show-bin-path)/tokiwatari"
[[ -x "$BIN" ]] || { echo "error: $BIN missing; run scripts/build-release.sh first" >&2; exit 1; }
ACTUAL="$("$BIN" --version)"
[[ "$ACTUAL" == "$VERSION" ]] \
  || { echo "error: binary reports $ACTUAL, expected $VERSION; run scripts/build-release.sh $VERSION" >&2; exit 1; }

NAME="tokiwatari-cli-v${VERSION}-darwin-arm64"
STAGE="$OUT/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/skills"
cp "$BIN" "$STAGE/"
rsync -a --exclude='.*' skills/tokiwatari "$STAGE/skills/"
cp LICENSE THIRD_PARTY_LICENSES README.md "$STAGE/"
tar -czf "$OUT/$NAME.tar.gz" -C "$OUT" "$NAME"
rm -rf "$STAGE"

echo "$OUT/$NAME.tar.gz"
