#!/bin/bash
# Verify the license files exist and every SwiftPM dependency (transitive
# included) is listed in THIRD_PARTY_LICENSES.
set -euo pipefail

[[ -s LICENSE ]] || { echo "error: LICENSE is missing or empty" >&2; exit 1; }
[[ -s THIRD_PARTY_LICENSES ]] || { echo "error: THIRD_PARTY_LICENSES is missing or empty" >&2; exit 1; }

STATUS=0
while IFS= read -r name; do
  grep -qF "$name" THIRD_PARTY_LICENSES \
    || { echo "error: dependency '$name' is not listed in THIRD_PARTY_LICENSES" >&2; STATUS=1; }
done < <(swift package show-dependencies --format json \
           | jq -r '.dependencies | .. | objects | select(has("name")) | .name' | sort -u)
exit $STATUS
