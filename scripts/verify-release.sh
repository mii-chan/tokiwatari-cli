#!/bin/bash
# Extract a distribution archive and verify its contents end-to-end.
# usage: scripts/verify-release.sh <archive.tar.gz> <version>
set -euo pipefail
ARCHIVE="${1:?usage: verify-release.sh <archive.tar.gz> <version>}"
VERSION="${2:?usage: verify-release.sh <archive.tar.gz> <version>}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$ARCHIVE" -C "$TMP"
ROOT="$TMP/tokiwatari-cli-v${VERSION}-darwin-arm64"
[[ -d "$ROOT" ]] || { echo "error: archive lacks the tokiwatari-cli-v${VERSION}-darwin-arm64/ root" >&2; exit 1; }

for file in tokiwatari skills/tokiwatari/SKILL.md skills/tokiwatari/references/schema.md \
            LICENSE THIRD_PARTY_LICENSES README.md; do
  [[ -s "$ROOT/$file" ]] || { echo "error: missing or empty in archive: $file" >&2; exit 1; }
done

HIDDEN="$(find "$ROOT" -mindepth 1 -name '.*')"
[[ -z "$HIDDEN" ]] || { echo "error: hidden files in archive:" >&2; echo "$HIDDEN" >&2; exit 1; }

lipo -archs "$ROOT/tokiwatari" | grep -qw arm64 \
  || { echo "error: binary is not arm64 (got: $(lipo -archs "$ROOT/tokiwatari"))" >&2; exit 1; }
[[ "$("$ROOT/tokiwatari" --version)" == "$VERSION" ]] \
  || { echo "error: --version mismatch" >&2; exit 1; }
"$ROOT/tokiwatari" --help > /dev/null

# install-skill must discover the sibling skills/ directory in the extracted layout.
env -u TOKIWATARI_SKILLS_PATH "$ROOT/tokiwatari" install-skill --dest "$TMP/skill-dest" > /dev/null
[[ -s "$TMP/skill-dest/SKILL.md" && -s "$TMP/skill-dest/references/schema.md" ]] \
  || { echo "error: install-skill from the archive layout failed" >&2; exit 1; }

echo "ok: $ARCHIVE"
