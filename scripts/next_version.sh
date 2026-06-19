#!/bin/bash
# Prints the next release version as YYYY.MM.DD.N, where N is the build
# counter for today (1 for the first release cut today, 2 for the second...).
# Determined by scanning existing `vYYYY.MM.DD.*` git tags.
set -euo pipefail

today=$(date +%Y.%m.%d)

last_n=$(git tag -l "v${today}.*" | sed "s/^v${today}\.//" | sort -n | tail -1)
next_n=$(( ${last_n:-0} + 1 ))

echo "${today}.${next_n}"
