#!/bin/zsh
# Usage: ./build.sh [--install|--release]
#   (nothing)   build/YANA.app for this Mac
#   --install   also replace /Applications/YANA.app and open it
#   --release   universal build, signed and notarized when it can be, zipped to downloads/YANA.zip with
#               downloads/latest.json for Check for Updates
set -euo pipefail
cd "$(dirname "$0")"

NAME="YANA"
APP="build/$NAME.app"
MODE="${1:-}"

# Releases also cover Intel
ARCHS=()
[[ "$MODE" == "--release" ]] && ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon from the 1024-pixel master
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# A Developer ID Application certificate in the keychain signs it, with the hardened runtime that notarization needs.
# YANA_SIGNING_IDENTITY picks one by name or SHA-1. Without one, it's signed ad hoc. See docs/signing.md.
IDENTITY="${YANA_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | awk '/"Developer ID Application/ { print $2; exit }')"
fi
TEAM=""
if [[ -n "$IDENTITY" ]]; then
    codesign --force --options runtime --timestamp --strip-disallowed-xattrs --sign "$IDENTITY" "$APP"
    TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$TEAM" == "not set" ]] && TEAM=""
    SIGNED_BY="Developer ID, team $TEAM"
else
    codesign --force --strip-disallowed-xattrs --sign - "$APP"
    SIGNED_BY="ad hoc"
fi
echo "Built $APP (signed $SIGNED_BY)"

# Notarizes with an app-specific password, so Gatekeeper opens it without a warning. Apple usually takes minutes, but a
# new team's first submissions can take hours. Then NOTARY_REQUIRED (releases) stops here, and anything else carries on
# unnotarized.
NOTARIZED=false
if [[ -n "$TEAM" && -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
    notary() { xcrun notarytool "$@" --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$TEAM" }
    ditto -c -k --keepParent "$APP" build/notarize.zip
    # The result goes to stdout, or to stderr when the wait runs out
    notary submit build/notarize.zip --wait --timeout "${NOTARY_TIMEOUT:-60m}" --output-format json \
        > build/notary.out 2>&1 || true
    rm -f build/notarize.zip
    cat build/notary.out
    STATUS="$(sed -nE 's/.*"status" *: *"([^"]+)".*/\1/p' build/notary.out | head -1)"
    SUBMISSION="$(sed -nE 's/.*"id" *: *"([0-9a-fA-F-]{36})".*/\1/p' build/notary.out | head -1)"
    if [[ "$STATUS" == "Accepted" ]]; then
        xcrun stapler staple "$APP"
        NOTARIZED=true
        echo "Notarized and stapled"
    elif [[ -n "$SUBMISSION" && ( -z "$STATUS" || "$STATUS" == "In Progress" ) ]]; then
        echo "Apple is still notarizing submission $SUBMISSION. Its recent submissions:"
        notary history 2>&1 | head -12 || true
        if [[ -n "${NOTARY_REQUIRED:-}" ]]; then
            echo "Stopping rather than publishing it unnotarized. Run this again once Apple finishes." >&2
            exit 1
        fi
        echo "::warning::Apple hasn't finished notarizing submission $SUBMISSION yet, so this build isn't notarized."
    else
        [[ -n "$SUBMISSION" ]] && notary log "$SUBMISSION" || true
        echo "Notarization failed${STATUS:+ ($STATUS)}" >&2
        exit 1
    fi
elif [[ -n "$TEAM" ]]; then
    echo "Not notarized: set NOTARY_APPLE_ID and NOTARY_PASSWORD to notarize."
fi

if [[ "$MODE" == "--install" ]]; then
    if pkill -x "$NAME"; then
        for _ in {1..25}; do
            pgrep -x "$NAME" >/dev/null || break
            sleep 0.2
        done
    fi
    rm -rf "/Applications/$NAME.app"
    ditto "$APP" "/Applications/$NAME.app"
    open "/Applications/$NAME.app"
    echo "Installed /Applications/$NAME.app"
fi

if [[ "$MODE" == "--release" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
    # Fixed name keeps the README's download link stable
    ZIP="downloads/$NAME.zip"
    mkdir -p downloads
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    # Left out when signed ad hoc, since plutil can't read a JSON null
    TEAM_LINE=""
    [[ -n "$TEAM" ]] && TEAM_LINE="  \"team\": \"$TEAM\","
    # What Check for Updates reads. The hash lets it reject a stale or broken download.
    cat > downloads/latest.json <<JSON
{
  "version": "$VERSION",
  "url": "https://github.com/jfreema/Yet-Another-Notes-App/raw/main/downloads/$NAME.zip",
  "sha256": "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)",
$TEAM_LINE
  "notarized": $NOTARIZED
}
JSON
    # README shows the version next to the download link
    sed -i '' -E "s/Version [0-9.]+ ·/Version $VERSION ·/" README.md
    echo "Built $ZIP ($VERSION) and downloads/latest.json"
fi
