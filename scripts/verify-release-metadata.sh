#!/bin/bash
# Verify the release version matches Version.swift and the tag does not exist yet.
# usage: scripts/verify-release-metadata.sh <version>
set -euo pipefail
VERSION="${1:?usage: verify-release-metadata.sh <version>}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "error: invalid version format: $VERSION (expected e.g. 0.1.0)" >&2; exit 1; }

grep -q "static let version = \"${VERSION}\"" Sources/Tokiwatari/Version.swift \
  || { echo "error: Sources/Tokiwatari/Version.swift is not ${VERSION}" >&2; exit 1; }

if git rev-parse -q --verify "refs/tags/v${VERSION}" > /dev/null; then
  echo "error: tag v${VERSION} already exists" >&2
  exit 1
fi
