#!/usr/bin/env bash
# Package the bridge extension as a .vsix (a zip with a manifest) using only
# zip(1) — no node_modules, no vsce. Output path is printed on stdout.
# Usage: vscode-extension/pack.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")"
OUT_DIR="${1:-../.build}"
NAME=$(python3 -c "import json; print(json.load(open('package.json'))['name'])")
VERSION=$(python3 -c "import json; print(json.load(open('package.json'))['version'])")
PUBLISHER=$(python3 -c "import json; print(json.load(open('package.json'))['publisher'])")
DESC=$(python3 -c "import json; print(json.load(open('package.json'))['description'])")
DISPLAY=$(python3 -c "import json; print(json.load(open('package.json'))['displayName'])")

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/extension"
cp package.json extension.js "$STAGE/extension/"
[[ -f README.md ]] && cp README.md "$STAGE/extension/"

cat >"$STAGE/[Content_Types].xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="json" ContentType="application/json"/>
  <Default Extension="js" ContentType="application/javascript"/>
  <Default Extension="md" ContentType="text/markdown"/>
  <Default Extension="vsixmanifest" ContentType="text/xml"/>
</Types>
XML

cat >"$STAGE/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011" xmlns:d="http://schemas.microsoft.com/developer/vsx-schema-design/2011">
  <Metadata>
    <Identity Language="en-US" Id="${NAME}" Version="${VERSION}" Publisher="${PUBLISHER}"/>
    <DisplayName>${DISPLAY}</DisplayName>
    <Description xml:space="preserve">${DESC}</Description>
    <Tags></Tags>
    <Categories>Other</Categories>
    <GalleryFlags>Public</GalleryFlags>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0"/>
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui"/>
    </Properties>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code"/>
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/>
  </Assets>
</PackageManifest>
XML

mkdir -p "$OUT_DIR"
OUT="$(cd "$OUT_DIR" && pwd)/${NAME}-${VERSION}.vsix"
rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OUT" .)
echo "$OUT"
