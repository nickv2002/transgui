#!/bin/bash
# Cuts a release: bumps the version, builds + signs + notarizes, generates a
# changelog, tags, pushes, publishes a GitHub Release, and installs the build
# into /Applications. The only command the owner needs to run.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
  echo "error: must be on main (currently on $branch)" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean" >&2
  exit 1
fi

version=$(scripts/next_version.sh)
tag="v${version}"
prev_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)

echo "==> releasing ${tag} (previous tag: ${prev_tag:-none})"

echo "==> updating project.yml version"
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${version}\"/" project.yml
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"${version}\"/" project.yml

scripts/build_release.sh
scripts/notarize.sh "$version"
scripts/changelog.sh "$version" "$prev_tag"

echo "==> committing version bump + changelog"
git add project.yml CHANGELOG.md
git commit -m "Release ${version}"

echo "==> tagging ${tag}"
git tag "$tag"

echo "==> pushing"
git push
git push --tags

echo "==> creating GitHub release"
gh release create "$tag" "dist/Transmission Remote-${version}.zip" \
  --title "${version}" --notes-file build/release-notes.md

scripts/install_local.sh

echo "==> done: ${tag}"
