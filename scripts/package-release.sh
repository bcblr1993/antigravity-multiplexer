#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to a Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
APP='Antigravity 多开管理器.app'
NAME="Antigravity-Multiplexer-v${VERSION}-macos-arm64"
ACCOUNT='AntigravityMultiplexer'
GENERATOR='.build/artifacts/sparkle/Sparkle/bin/generate_appcast'
mkdir -p dist

./build.sh
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" == \
   "$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account "$ACCOUNT" -p | tail -1 | tr -d '[:space:]')" ]] || {
  echo 'Sparkle public key does not match the release signing account' >&2
  exit 1
}

NOTARY_ZIP="dist/${NAME}-notary.zip"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" \
  --wait --timeout 20m --output-format json > dist/notarization.json
python3 - <<'PY'
import json
record=json.load(open('dist/notarization.json'))
print('Notarization:',record.get('status'),'id:',record.get('id'))
raise SystemExit(0 if record.get('status')=='Accepted' else 1)
PY
SUBMISSION_ID="$(python3 -c 'import json; print(json.load(open("dist/notarization.json"))["id"])')"
xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" \
  --output-format json > dist/notarization-log.json
python3 - <<'PY'
import json
record=json.load(open('dist/notarization-log.json'))
issues=record.get('issues') or []
print('Notary issues:',len(issues))
raise SystemExit(0 if record.get('status')=='Accepted' and not issues else 1)
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP"

ARCHIVE="dist/${NAME}.zip"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
unzip -tq "$ARCHIVE"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/antigravity-appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$ARCHIVE" "$STAGE/"
cp RELEASE_NOTES.md "$STAGE/${NAME}.md"
"$GENERATOR" --account "$ACCOUNT" --embed-release-notes \
  --download-url-prefix "https://github.com/bcblr1993/antigravity-multiplexer/releases/download/v${VERSION}/" \
  "$STAGE"
cp "$STAGE/appcast.xml" dist/appcast.xml
python3 - "$VERSION" "$NAME" <<'PY'
import sys,xml.etree.ElementTree as ET
version,name=sys.argv[1:]
root=ET.parse('dist/appcast.xml')
ns={'s':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items=root.findall('./channel/item')
assert len(items)==1
item=items[0]
assert item.findtext('s:shortVersionString',namespaces=ns)==version
enclosure=item.find('enclosure')
assert enclosure.get('{'+ns['s']+'}edSignature')
assert enclosure.get('url')==f'https://github.com/bcblr1993/antigravity-multiplexer/releases/download/v{version}/{name}.zip'
print('Appcast version, URL and EdDSA signature verified')
PY
".build/artifacts/sparkle/Sparkle/bin/sign_update" --account "$ACCOUNT" --verify dist/appcast.xml
SIGNATURE="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
root=ET.parse('dist/appcast.xml').getroot()
print(root.find('./channel/item/enclosure').get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature'))
PY
)"
".build/artifacts/sparkle/Sparkle/bin/sign_update" --account "$ACCOUNT" --verify "$ARCHIVE" "$SIGNATURE"
(cd dist && shasum -a 256 "${NAME}.zip" appcast.xml > SHA256SUMS.txt)
echo "Release files ready in dist/: ${NAME}.zip, appcast.xml, SHA256SUMS.txt"
