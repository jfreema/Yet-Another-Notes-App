# Signing and notarizing YANA

Releases are signed with a **Developer ID Application** certificate and notarized by Apple, so YANA opens on any Mac
without a Gatekeeper warning. This doesn't involve the App Store. The Release workflow does both when the four secrets
below are set, and signs ad hoc when they aren't.

## 1. Make the Developer ID Application certificate (once)

Only the Apple Developer account holder can make one.

1. Open **Xcode → Settings → Accounts**, add your Apple ID if it isn't there, select your team and click
   **Manage Certificates…**.
2. Click **+** and choose **Developer ID Application**. Xcode creates it and puts it, with its private key, in your
   login keychain.

(Without Xcode: make a certificate signing request in **Keychain Access → Certificate Assistant → Request a Certificate
From a Certificate Authority…**, upload it at
[developer.apple.com → Certificates](https://developer.apple.com/account/resources/certificates/add), choose
**Developer ID Application**, and double-click the downloaded certificate.)

## 2. Export it as a .p12

1. Open **Keychain Access**, choose the **login** keychain and the **My Certificates** tab.
2. Right-click **Developer ID Application: <your name> (<team ID>)** and choose **Export…**.
3. Save it as `DeveloperID.p12` and give it a password.
4. In Terminal, copy it as base64:

   ```sh
   base64 -i ~/Desktop/DeveloperID.p12 | pbcopy
   ```

Keep the .p12 somewhere safe, like a password manager, and delete the loose copy.

## 3. Make an app-specific password for notarizing

1. Sign in at [account.apple.com](https://account.apple.com) and open **Sign-In and Security → App-Specific Passwords**.
2. Click **+**, name it `YANA notarization`, and copy the password.

## 4. Add the secrets to GitHub

In the repo, open **Settings → Secrets and variables → Actions** and click **New repository secret** for each:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_P12` | The base64 text from step 2 |
| `DEVELOPER_ID_P12_PASSWORD` | The .p12's password |
| `NOTARY_APPLE_ID` | Your Apple ID email |
| `NOTARY_PASSWORD` | The app-specific password from step 3 |

The team ID comes from the certificate, so it isn't a secret.

## How it fits together

- `build.sh` signs with the first **Developer ID Application** identity in the keychain, using the hardened runtime,
  then notarizes and staples when `NOTARY_APPLE_ID` and `NOTARY_PASSWORD` are set. `YANA_SIGNING_IDENTITY` picks a
  different identity.
- `downloads/latest.json` records the signing team. Once a Developer ID release is out, Check for Updates only installs
  updates signed by the same team, and the workflow refuses to publish anything else.
- The certificate lasts five years. A renewed one from the same team keeps working with Check for Updates.
- YANA asks for no macOS permissions, so changing how it's signed never makes anyone grant anything again.
