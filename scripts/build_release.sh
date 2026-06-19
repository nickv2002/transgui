#!/bin/bash
# Archives and exports a Developer-ID-signed Release build of the app.
# Produces build/export/Transmission Remote.app.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

archive_path="build/TransmissionRemote.xcarchive"
export_path="build/export"

echo "==> xcodegen generate"
xcodegen generate

echo "==> archiving (Release)"
rm -rf "$archive_path"
xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
  -configuration Release clean archive -archivePath "$archive_path"

echo "==> exporting signed .app"
rm -rf "$export_path"
xcodebuild -exportArchive -archivePath "$archive_path" \
  -exportPath "$export_path" -exportOptionsPlist scripts/ExportOptions.plist

echo "==> exported: $export_path/Transmission Remote.app"
