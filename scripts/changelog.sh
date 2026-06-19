#!/bin/bash
# Generates a changelog section for <version> from commits since <prev-tag>
# (or full history if there is no previous tag), prepends it to
# CHANGELOG.md, and writes the same section body to build/release-notes.md
# for use as the GitHub release body.
#
# Usage: scripts/changelog.sh <version> [prev-tag]
set -euo pipefail

version="${1:?usage: changelog.sh <version> [prev-tag]}"
prev_tag="${2:-}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

changelog_file="CHANGELOG.md"
notes_file="build/release-notes.md"
mkdir -p build

range="HEAD"
if [[ -n "$prev_tag" ]]; then
  range="${prev_tag}..HEAD"
fi

date_str=$(date +%Y-%m-%d)

{
  echo "## ${version} — ${date_str}"
  echo
  git log "$range" --oneline --no-merges --pretty=format:'- %s'
  echo
} > "$notes_file"

if [[ ! -f "$changelog_file" ]]; then
  echo "# Changelog" > "$changelog_file"
  echo >> "$changelog_file"
fi

tmp_file=$(mktemp)
{
  head -n 2 "$changelog_file"
  cat "$notes_file"
  echo
  tail -n +3 "$changelog_file"
} > "$tmp_file"
mv "$tmp_file" "$changelog_file"

echo "==> changelog section written to $notes_file and prepended to $changelog_file"
