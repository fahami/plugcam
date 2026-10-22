#!/usr/bin/env bash
# Builds Plugcam.app for macOS: the Rust app (Tauri), the camera extension (Xcode), adb, signed
# together with your Apple developer team.
#
#   scripts/macos-build.sh                 # build src-tauri/target/<profile>/bundle/macos/Plugcam.app
#   scripts/macos-build.sh --install       # ...and copy it to /Applications (needed to add the camera)
#   scripts/macos-build.sh --dmg           # ...and pack it into a .dmg
#   scripts/macos-build.sh --download-adb  # take the latest platform-tools from Google, not the adb on PATH
#
# Environment:
#   PLUGCAM_SIGN_IDENTITY  codesign identity (default: the first "Apple Development" one)
#   PLUGCAM_TEAM           team ID (default: the identity's team)
#   PLUGCAM_BUNDLE_ID      app bundle ID (default: io.github.plugcam); the camera is <id>.camera
#   PLUGCAM_PROFILE        cargo profile (default: release; release-fast builds much faster)
#
# Xcode must be signed in to the team's Apple account (Xcode > Settings > Accounts): the first
# build registers the bundle IDs with the System Extension capability and makes the profile.
# macOS only installs camera extensions of apps in /Applications.
set -euo pipefail

install=0
dmg=0
download_adb=0
for arg in "$@"; do
    case "$arg" in
    --install) install=1 ;;
    --dmg) dmg=1 ;;
    --download-adb) download_adb=1 ;;
    *)
        echo "unknown option: $arg" >&2
        exit 2
        ;;
    esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
res="$root/src-tauri/resources"
work="$root/macos/build"
profile="${PLUGCAM_PROFILE:-release}"
bundle_id="${PLUGCAM_BUNDLE_ID:-io.github.plugcam}"
version="$(node -p "require('$root/src-tauri/tauri.conf.json').version")"

identity="${PLUGCAM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if [[ -z "$identity" ]]; then
    echo "no codesigning identity: sign in to Xcode with your Apple account, or set PLUGCAM_SIGN_IDENTITY" >&2
    exit 1
fi
team="${PLUGCAM_TEAM:-$(security find-certificate -c "$identity" -p | openssl x509 -noout -subject -nameopt multiline | sed -n 's/ *organizationalUnitName *= *//p' | head -1)}"
echo "signing as \"$identity\" (team $team), $bundle_id $version"

# 1. adb from Android platform-tools, next to scrcpy-server in the app's resources.
mkdir -p "$res/licenses"
if [[ $download_adb == 1 ]]; then
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/pt.zip" https://dl.google.com/android/repository/platform-tools-latest-darwin.zip
    unzip -q "$tmp/pt.zip" -d "$tmp"
    tools="$tmp/platform-tools"
else
    adb="$(command -v adb || true)"
    if [[ -z "$adb" ]]; then
        echo "adb is not on PATH: install android-platform-tools or pass --download-adb" >&2
        exit 1
    fi
    tools="$(dirname "$(realpath "$adb")")"
fi
cp "$tools/adb" "$res/adb"
if [[ -f "$tools/NOTICE.txt" ]]; then cp "$tools/NOTICE.txt" "$res/licenses/platform-tools-NOTICE.txt"; fi

# 2. The camera extension, and the provisioning profile for the app (see macos/SigningHost).
(cd "$root/macos" && xcodegen generate --quiet)
xcodebuild -project "$root/macos/PlugcamMac.xcodeproj" -scheme Plugcam -configuration Release \
    -derivedDataPath "$work" -allowProvisioningUpdates -quiet \
    DEVELOPMENT_TEAM="$team" PLUGCAM_BUNDLE_ID="$bundle_id" \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$version" build
host="$work/Build/Products/Release/Plugcam.app"
extension="$host/Contents/Library/SystemExtensions/$bundle_id.camera.systemextension"

# 3. The app. Tauri does not sign it (step 4 does) or make updater files (they need the key).
config="{\"identifier\":\"$bundle_id\",\"bundle\":{\"createUpdaterArtifacts\":false}}"
(cd "$root" && env -u APPLE_SIGNING_IDENTITY -u APPLE_CERTIFICATE pnpm tauri build --bundles app --config "$config" \
    $([[ $profile != release ]] && echo "-- --profile $profile"))
app="$root/src-tauri/target/$profile/bundle/macos/Plugcam.app"

# 4. Extension and profile into the app, then sign it with the entitlements the profile allows.
mkdir -p "$app/Contents/Library/SystemExtensions"
rm -rf "$app/Contents/Library/SystemExtensions/"*
cp -R "$extension" "$app/Contents/Library/SystemExtensions/"
cp "$host/Contents/embedded.provisionprofile" "$app/Contents/"
codesign -d --entitlements - --xml "$host" >"$work/Plugcam.entitlements" 2>/dev/null
codesign --force --options runtime --sign "$identity" "$app/Contents/Resources/resources/adb"
codesign --force --options runtime --entitlements "$work/Plugcam.entitlements" --sign "$identity" "$app"
codesign --verify --strict --deep "$app"
echo "built $app"

if [[ $install == 1 ]]; then
    osascript -e 'quit app "Plugcam"' 2>/dev/null || true
    rm -rf /Applications/Plugcam.app
    cp -R "$app" /Applications/
    echo "installed /Applications/Plugcam.app"
fi

if [[ $dmg == 1 ]]; then
    arch="$(uname -m)"
    out="$root/src-tauri/target/$profile/bundle/dmg/Plugcam_${version}_${arch}.dmg"
    mkdir -p "$(dirname "$out")"
    stage="$(mktemp -d)"
    cp -R "$app" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname Plugcam -srcfolder "$stage" -ov -format UDZO "$out"
    codesign --sign "$identity" "$out"
    echo "packed $out"
fi
