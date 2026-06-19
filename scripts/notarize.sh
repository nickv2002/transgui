#!/bin/bash
# Notarizes and staples the exported .app, then zips the stapled app into
# dist/Transmission Remote-<version>.zip — the artifact uploaded to GitHub.
#
# The App Store Connect API key is pulled live from 1Password on every run
# (op CLI — prompts for unlock/approval each time). Nothing is ever stored
# in the macOS keychain; the key only ever touches disk as a 0600 file in a
# 0700 temp dir that's deleted on exit (success or failure).
#
# Usage: scripts/notarize.sh <version>
set -euo pipefail

version="${1:?usage: notarize.sh <version>}"
op_account="nickfam.1password.com"
op_vault="Private"
op_item_name="App Store Connect API Key File"
op_item="op://${op_vault}/${op_item_name}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

app_path="build/export/Transmission Remote.app"
submit_zip="build/notarize-submission.zip"
dist_dir="dist"
dist_zip="$dist_dir/Transmission Remote-${version}.zip"

if [[ ! -d "$app_path" ]]; then
  echo "error: $app_path not found — run scripts/build_release.sh first" >&2
  exit 1
fi

echo "==> fetching App Store Connect API key from 1Password (${op_item})"
key_filename=$(op item get "$op_item_name" --vault "$op_vault" --account "$op_account" --format json \
  | /usr/bin/python3 -c 'import json, sys; print(json.load(sys.stdin)["files"][0]["name"])')
key_id=$(echo "$key_filename" | sed -E 's/^AuthKey_([A-Za-z0-9]+)\.p8$/\1/')
issuer_id=$(op read "${op_item}/issuer id" --account "$op_account")

secret_dir=$(mktemp -d)
trap 'rm -rf "$secret_dir"' EXIT
chmod 700 "$secret_dir"
key_path="${secret_dir}/${key_filename}"
op read "${op_item}/${key_filename}" --account "$op_account" --out-file "$key_path" >/dev/null
chmod 600 "$key_path"

echo "==> zipping for submission"
rm -f "$submit_zip"
ditto -c -k --keepParent "$app_path" "$submit_zip"

echo "==> submitting to notarytool (key id: $key_id)"
xcrun notarytool submit "$submit_zip" \
  --key "$key_path" --key-id "$key_id" --issuer "$issuer_id" --wait

echo "==> stapling ticket"
xcrun stapler staple "$app_path"

echo "==> verifying"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose "$app_path"

echo "==> zipping stapled app for release"
mkdir -p "$dist_dir"
rm -f "$dist_zip"
ditto -c -k --keepParent "$app_path" "$dist_zip"

echo "==> notarized artifact: $dist_zip"
