#!/bin/zsh
# Usage: ./build.sh [--install|--release]
#   (nothing)   build/YANA.app for this Mac
#   --install   also replace /Applications/YANA.app and open it
#   --release   universal build, signed and notarized when it can be, zipped to downloads/YANA.zip with
#               downloads/latest.json for Check for Updates. The Release workflow publishes the zip as a GitHub
#               Release and commits latest.json. The zip itself isn't committed.
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
# A space or line break pasted along with a secret makes Apple turn down the sign-in, and neither an Apple ID nor an
# app-specific password has one
NOTARY_APPLE_ID="${${NOTARY_APPLE_ID:-}//[[:space:]]/}"
NOTARY_PASSWORD="${${NOTARY_PASSWORD:-}//[[:space:]]/}"

# When Apple turns down the sign-in: what the two secrets look like, never what they are, since the log may be public.
# The fingerprint is too short to give the password away, but changes when it does.
notary_secrets() {
    echo "What the notarization secrets look like:"
    if [[ "$NOTARY_APPLE_ID" == ?*@?*.?* ]]; then
        echo "  NOTARY_APPLE_ID looks like an email address"
    else
        echo "  NOTARY_APPLE_ID doesn't look like an email address"
    fi
    if [[ "$NOTARY_PASSWORD" =~ '^[a-zA-Z]{4}-[a-zA-Z]{4}-[a-zA-Z]{4}-[a-zA-Z]{4}$' ]]; then
        echo "  NOTARY_PASSWORD has the shape of an app-specific password (xxxx-xxxx-xxxx-xxxx)"
    else
        echo "  NOTARY_PASSWORD doesn't have the shape of an app-specific password (xxxx-xxxx-xxxx-xxxx): it has ${#NOTARY_PASSWORD} characters"
    fi
    echo "  NOTARY_PASSWORD fingerprint: $(printf '%s' "$NOTARY_PASSWORD" | shasum -a 256 | cut -c1-6)"
    echo "Make an app-specific password at account.apple.com, signed in with the Apple ID in NOTARY_APPLE_ID, and put it in"
    echo "the repository secret NOTARY_PASSWORD (Settings › Secrets and variables › Actions › Repository secrets). See"
    echo "docs/signing.md."
}

if [[ -n "$TEAM" && -n "$NOTARY_APPLE_ID" && -n "$NOTARY_PASSWORD" ]]; then
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
        grep -q "401" build/notary.out && notary_secrets
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
    # Always the same name, so the README's link to the latest release's YANA.zip keeps working
    ZIP="downloads/$NAME.zip"
    mkdir -p downloads
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    # Left out when signed ad hoc, since plutil can't read a JSON null
    TEAM_LINE=""
    [[ -n "$TEAM" ]] && TEAM_LINE="  \"team\": \"$TEAM\","
    # What Check for Updates reads, from main. The address is the zip attached to this version's GitHub Release, and
    # the hash lets it reject a stale or broken download.
    cat > downloads/latest.json <<JSON
{
  "version": "$VERSION",
  "url": "https://github.com/jfreema/Yet-Another-Notes-App/releases/download/v$VERSION/$NAME.zip",
  "sha256": "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)",
$TEAM_LINE
  "notarized": $NOTARIZED
}
JSON
    # README shows the version next to the download link
    sed -i '' -E "s/Version [0-9.]+ ·/Version $VERSION ·/" README.md
    echo "Built $ZIP ($VERSION) and downloads/latest.json"
fi
