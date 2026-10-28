#!/bin/bash
# Drive to Finder — build the hosted extension + IT files. Run on a Mac with Google Chrome.
#   ./build.sh <OAUTH_CLIENT_ID> <HOSTING_BASE_URL>
#   e.g. ./build.sh 1234-abc.apps.googleusercontent.com https://apparent.github.io/drive-to-finder
# Output (dist/): drive-to-finder.crx + update.xml  -> upload both to HOSTING_BASE_URL
#                 chrome-policy.mobileconfig + install-helper.sh -> give to IT for Iru
set -euo pipefail
cd "$(dirname "$0")"

CLIENT_ID="${1:?Pass the OAuth client ID}"
BASE_URL="${2:?Pass the https URL where the .crx and update.xml will live}"
BASE_URL="${BASE_URL%/}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

rm -rf dist && mkdir -p dist
cp -R extension dist/extension
perl -pi -e "s/REPLACE_WITH_OAUTH_CLIENT_ID\.apps\.googleusercontent\.com/$CLIENT_ID/" dist/extension/manifest.json
VERSION=$(perl -ne 'print $1 if /"version":\s*"([^"]+)"/' dist/extension/manifest.json)
EXT_ID=$(cat keys/extension-id.txt)

echo "Packing v$VERSION ($EXT_ID)…"
if command -v npx >/dev/null 2>&1; then
  npx --yes crx3@1 -p keys/extension-key.pem -o dist/drive-to-finder.crx dist/extension
else
  "$CHROME" --pack-extension="$PWD/dist/extension" --pack-extension-key="$PWD/keys/extension-key.pem" --no-message-box || true
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -f dist/extension.crx ] && break; sleep 1; done
  mv dist/extension.crx dist/drive-to-finder.crx
fi

cat > dist/update.xml <<XML
<?xml version='1.0' encoding='UTF-8'?>
<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>
  <app appid='$EXT_ID'>
    <updatecheck codebase='$BASE_URL/drive-to-finder.crx' version='$VERSION' />
  </app>
</gupdate>
XML

perl -pe "s#__UPDATE_URL__#$BASE_URL/update.xml#" deploy/chrome-policy.template.mobileconfig > dist/chrome-policy.mobileconfig
cp deploy/install-helper.sh deploy/uninstall-helper.sh dist/

echo
echo "Done. Upload dist/drive-to-finder.crx and dist/update.xml to $BASE_URL/"
echo "Then give IT: dist/install-helper.sh (Custom Script) and dist/chrome-policy.mobileconfig (Custom Profile)."
