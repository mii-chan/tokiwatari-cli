#!/bin/bash
# Generate release notes via the GitHub "generate-notes" API and print the body
# to stdout. On the first release (no previous v* tag) previous_tag_name is omitted.
# usage: scripts/generate-release-notes.sh <version>
# requires: gh (authenticated), GITHUB_REPOSITORY, full git history (fetch-depth: 0)
set -euo pipefail
VERSION="${1:?usage: generate-release-notes.sh <version>}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required (owner/repo)}"

ARGS=(-f "tag_name=v${VERSION}" -f "target_commitish=main")
if PREVIOUS="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null)"; then
  ARGS+=(-f "previous_tag_name=${PREVIOUS}")
fi
gh api --method POST "repos/${REPO}/releases/generate-notes" "${ARGS[@]}" --jq .body
