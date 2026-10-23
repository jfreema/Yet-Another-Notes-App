#!/bin/zsh
# Makes YANA's Developer ID certificate and adds the four secrets the Release workflow signs and notarizes with.
# Run it once on your Mac, in Terminal:  zsh setup-signing.sh
#
# You sign in to Apple twice: to turn a signing request into a certificate, and to make an app-specific password.
# Everything else happens here. The private key is made on this Mac and only goes to your login keychain and to the
# repo's encrypted secrets. Nothing secret is printed. See docs/signing.md.
set -euo pipefail

REPO="jfreema/Yet-Another-Notes-App"
# macOS's own OpenSSL, whose .p12 files the keychain reads
OPENSSL=/usr/bin/openssl
WORK="$(mktemp -d)"
CSR="$HOME/Desktop/YANA.certSigningRequest"
TEST_KEYCHAIN="$WORK/test.keychain-db"
USED_CLIPBOARD=0

cleanup() {
    security delete-keychain "$TEST_KEYCHAIN" 2>/dev/null || true
    rm -rf "$WORK"
    rm -f "$CSR"
    (( USED_CLIPBOARD )) && pbcopy < /dev/null
    return 0
}
trap cleanup EXIT
chmod 700 "$WORK"
touch "$WORK/started"

step() { print; print -P "%B$1%b" }
fail() { print -P "%F{red}$1%f" >&2 }
# Prompts printed by hand, since read only shows its own in an interactive shell
ask() { print -n -- "$2"; read -r "$1" }
ask_hidden() { print -n -- "$2"; read -rs "$1"; print }

print -P "%BYANA signing setup%b"
print "This makes a Developer ID certificate for $REPO and adds its signing secrets. It takes about 5 minutes."

# MARK: GitHub

if command -v gh >/dev/null && gh auth status --hostname github.com >/dev/null 2>&1 \
        && gh secret list --repo "$REPO" >/dev/null 2>&1; then
    USE_GH=1
    print "GitHub CLI is signed in, so the secrets go straight to the repo."
else
    USE_GH=0
    print "GitHub CLI isn't set up here, so at the end you'll paste each secret into GitHub's page. (To skip that, run"
    print "'brew install gh && gh auth login' first, then this again.)"
fi

# MARK: Certificate

step "1. Your Apple ID"
APPLE_ID=""
while [[ -z "$APPLE_ID" ]]; do
    ask APPLE_ID "The email you sign in to your Apple Developer account with: "
done

$OPENSSL req -new -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$CSR" \
    -subj "/emailAddress=$APPLE_ID/CN=$(id -F)" 2>/dev/null
chmod 600 "$WORK/key.pem"

step "2. Make the certificate on Apple's site"
print "Opening developer.apple.com. There:"
print "  a. Sign in if asked."
print "  b. Choose 'Developer ID Application' and click Continue."
print "  c. Select 'G2 Sub-CA'. (Apple preselects 'Previous Sub-CA', which expires in 2027.)"
print "     Click Choose File and pick YANA.certSigningRequest on your Desktop."
print "  d. Click Continue, then Download."
open "https://developer.apple.com/account/resources/certificates/add"

while true; do
    print
    ask answer "When it's downloaded, press Return. (Or drag the .cer file into this window first.) "
    cer="$(print -r -- "$answer" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    cer="${(Q)cer}"
    if [[ -z "$cer" ]]; then
        newest=(~/Downloads/*.cer(N.om[1]))
        if (( ${#newest} )) && [[ "${newest[1]}" -nt "$WORK/started" ]]; then
            cer="${newest[1]}"
        else
            fail "No new .cer file in Downloads yet."
            continue
        fi
    fi
    if ! $OPENSSL x509 -inform DER -in "$cer" -out "$WORK/cert.pem" 2>/dev/null \
            && ! $OPENSSL x509 -in "$cer" -out "$WORK/cert.pem" 2>/dev/null; then
        fail "$cer isn't a certificate."
        continue
    fi
    if [[ "$($OPENSSL x509 -noout -modulus -in "$WORK/cert.pem")" != "$($OPENSSL rsa -noout -modulus -in "$WORK/key.pem")" ]]; then
        fail "$cer was made from a different signing request. Download the one you just made."
        continue
    fi
    subject="$($OPENSSL x509 -noout -subject -in "$WORK/cert.pem")"
    if [[ "$subject" != *"Developer ID Application"* ]]; then
        fail "That's not a Developer ID Application certificate. Make it again and pick Developer ID Application."
        continue
    fi
    break
done
TEAM="$(print -r -- "$subject" | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p')"
NAME="$(print -r -- "$subject" | sed -nE 's/.*CN ?= ?(Developer ID Application: [^/,]*).*/\1/p')"
if [[ -z "$TEAM" || -z "$NAME" ]]; then
    fail "Couldn't read the team ID from the certificate ($subject)."
    exit 1
fi
print "Got $NAME"

# Apple's intermediate certificate goes in too, so the signature carries the whole chain wherever it's made
issuer="$($OPENSSL x509 -noout -issuer -in "$WORK/cert.pem" | sed 's/^issuer= *//')"
CHAIN=()
for ca in DeveloperIDG2CA DeveloperIDCA; do
    if curl -fsSL "https://www.apple.com/certificateauthority/$ca.cer" -o "$WORK/$ca.cer" 2>/dev/null \
            && $OPENSSL x509 -inform DER -in "$WORK/$ca.cer" -out "$WORK/$ca.pem" 2>/dev/null \
            && [[ "$($OPENSSL x509 -noout -subject -in "$WORK/$ca.pem" | sed 's/^subject= *//')" == "$issuer" ]]; then
        CHAIN=(-certfile "$WORK/$ca.pem")
        break
    fi
done

step "3. Package it"
P12="$WORK/DeveloperID.p12"
P12_PASSWORD="$($OPENSSL rand -base64 24)"
export P12_PASSWORD
package() {
    $OPENSSL pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" "${CHAIN[@]}" -name "$NAME" \
        -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -passout env:P12_PASSWORD -out "$P12" "$@"
}
# The SHA-1 MAC every macOS can read, where this OpenSSL has the option
package -macalg sha1 2>/dev/null || package

# Imports it the way the Release workflow will, to be sure it works there
security create-keychain -p "$P12_PASSWORD" "$TEST_KEYCHAIN"
security import "$P12" -k "$TEST_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
if ! security find-identity -p codesigning "$TEST_KEYCHAIN" | grep -q "Developer ID Application"; then
    fail "The packaged certificate didn't import. Nothing was uploaded."
    exit 1
fi
security delete-keychain "$TEST_KEYCHAIN"

# Your login keychain keeps a copy: it's the backup, and lets this Mac sign too
if security import "$P12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$P12_PASSWORD" \
        -T /usr/bin/codesign >/dev/null 2>&1; then
    print "Saved to your login keychain as \"$NAME\"."
else
    print "Couldn't add it to your login keychain. That's fine: the secret is what releases use."
fi

# MARK: Notarization

step "4. Make an app-specific password for notarizing"
print "Opening account.apple.com. There:"
print "  a. Sign in, then open Sign-In and Security, then App-Specific Passwords."
print "  b. Click + (or Generate), name it 'YANA notarization', and copy the password."
open "https://account.apple.com/account/manage"

can_check=0
xcrun --find notarytool >/dev/null 2>&1 && can_check=1
while true; do
    print
    ask_hidden NOTARY_PASSWORD "Paste the app-specific password and press Return (it stays hidden): "
    [[ -z "$NOTARY_PASSWORD" ]] && continue
    (( can_check )) || break
    print "Checking it with Apple..."
    if output="$(xcrun notarytool history --apple-id "$APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$TEAM" 2>&1)"; then
        print "Apple accepted it."
        break
    fi
    fail "Apple didn't accept it:"
    print -r -- "$output" | tail -3 >&2
    ask answer "Apple ID [$APPLE_ID] (press Return to keep it): "
    [[ -n "$answer" ]] && APPLE_ID="$answer"
done

# MARK: Secrets

step "5. Add the secrets to $REPO"
set_secret() {
    if (( USE_GH )); then
        printf '%s' "$2" | gh secret set "$1" --repo "$REPO"
    else
        printf '%s' "$2" | pbcopy
        USED_CLIPBOARD=1
        open "https://github.com/$REPO/settings/secrets/actions/new"
        print "In the page that opened: Name $1, paste into Secret (it's on your clipboard), click Add secret."
        ask answer "Then press Return here. "
    fi
}
set_secret DEVELOPER_ID_P12 "$(base64 -i "$P12")"
set_secret DEVELOPER_ID_P12_PASSWORD "$P12_PASSWORD"
set_secret NOTARY_APPLE_ID "$APPLE_ID"
set_secret NOTARY_PASSWORD "$NOTARY_PASSWORD"

print
print -P "%BDone.%b The next YANA release is signed by \"$NAME\" and notarized."
print "The temporary files are deleted. Your login keychain keeps the certificate as your backup."
