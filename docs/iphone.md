# YANA for iPhone

YANA for iPhone shows and edits the to-do lists YANA syncs, through the same sync folder your Macs use. Check tasks
off, change them, add them (Return in a task starts a new one below, as on the Mac), touch and hold one to drag it into order, and clear
the checked ones. Add the sync folder and YANA shows the lists in it to bring over. A list started on the iPhone can
be sent to your Macs with **Sync This List…**. Notes stay on the Mac: only lists come to the iPhone.

It syncs while it's open: when something changes in the sync folder, after each change you make, and as you leave it.
Changes made on a Mac while it's closed come in when you next open it. Pull down on a list to sync right away.

## Getting it onto your iPhone (once)

YANA for iPhone goes out through TestFlight. The **iPhone** workflow builds it on GitHub and sends it to App Store
Connect, and TestFlight puts it on your iPhone. Only you (the Apple Developer account holder) can do these steps.

### 1. Register the app's ID

1. Open [Certificates, Identifiers & Profiles › Identifiers › +](https://developer.apple.com/account/resources/identifiers/add/bundleId).
2. Choose **App IDs**, then **App**, and click **Continue**.
3. Description: `YANA for iPhone`. Bundle ID: **Explicit**, `io.github.jfreema.yana.ios`. Leave every capability off.
4. Click **Continue**, then **Register**.

### 2. Make the app in App Store Connect

1. Open [App Store Connect › Apps](https://appstoreconnect.apple.com/apps), click **+** and choose **New App**.
2. Platform: **iOS**. Name: anything no other app on the App Store uses, such as `YANA – Yet Another Notes App`
   (it only shows in App Store Connect and TestFlight; on the iPhone the app is called YANA). Primary language:
   **English (U.S.)**. Bundle ID: **io.github.jfreema.yana.ios** from step 1. SKU: `yana-ios`. User access:
   **Full Access**.
3. Click **Create**. Nothing else on the app's page needs filling in for TestFlight.

### 3. Make an App Store Connect API key

1. Open [App Store Connect › Users and Access › Integrations › App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api)
   and stay on **Team Keys**. If it asks, click **Request Access** first.
2. Click **+** (Generate API Key). Name: `YANA GitHub`. Access: **Admin**. Click **Generate**.

   Admin is what lets the workflow sign the app with a distribution certificate Apple keeps for your team, so there's
   no certificate or profile to make or renew by hand.
3. Click **Download** next to the new key. Apple only lets you download it once. It saves as
   `AuthKey_<Key ID>.p8` in Downloads.
4. Note the **Key ID** (in the key's row) and the **Issuer ID** (above the list of keys).

### 4. Put the key in the repo's secrets

In Terminal, with your Key ID and Issuer ID in place of the capitals:

```sh
cd ~/Downloads
gh secret set ASC_KEY_ID -R jfreema/Yet-Another-Notes-App -b "KEYID"
gh secret set ASC_ISSUER_ID -R jfreema/Yet-Another-Notes-App -b "ISSUER-ID"
gh secret set ASC_KEY -R jfreema/Yet-Another-Notes-App < AuthKey_KEYID.p8
```

Or add the three on [the repo's secrets page](https://github.com/jfreema/Yet-Another-Notes-App/settings/secrets/actions),
with the whole .p8 file (open it in TextEdit) as `ASC_KEY`. Then keep the .p8 somewhere safe, or delete it: you can
always make a new key.

### 5. Build it

On GitHub, open **Actions › iPhone › Run workflow**, leave it on **main** and click **Run workflow**. It takes about
10 minutes. Apple then processes the build, which takes another 5 to 15 minutes and sends you an email when it's done.

### 6. Install it with TestFlight

1. In App Store Connect, open the app, then **TestFlight**. Next to **Internal Testing**, click **+**, name the group
   `Me`, tick **Enable automatic distribution**, and click **Create**.
2. In the group, click **+** next to **Testers** and add yourself.
3. On your iPhone, install [TestFlight](https://apps.apple.com/app/testflight/id899247664) from the App Store, signed
   in with the same Apple ID. Open the invitation email on the iPhone (or just open TestFlight), and tap **Install**.

Every build from main goes to TestFlight from now on. TestFlight builds stop opening after 90 days, so the workflow
also sends one on the 1st of each month. Turn on **Automatic Updates** for YANA in TestFlight so you always have the
latest.

## Getting your lists onto it

1. On the iPhone, open YANA and tap **Add Sync Folder…**. In Files, go to **iCloud Drive** and pick the folder your
   Macs sync through: **YANA Sync**, or the folder you shared between your Apple IDs. A shared folder shows in iCloud
   Drive once you've accepted the invitation on that Apple ID.
2. YANA shows the lists your other devices sync through that folder, each with a switch. Leave on the ones you want
   and tap **Bring Here**. If iCloud Drive is still downloading the folder, they turn up after a moment.
3. In YANA's **Settings** (the gear), give the iPhone a name, like `Jared's iPhone`. Your Macs show that name.

Tap a folder in **Settings** to see its lists again. That's how you get a list you didn't bring over the first time,
or one you removed from the iPhone. A Mac can still send a list here itself: in the list's **Sync Settings for This
List…**, tick the iPhone.

To send a list from the iPhone to your Macs, open it and choose **Sync This List…** from the **…** menu. When
another device starts using a folder, YANA offers to send it the lists that sync through that folder. Swiping a
synced list away in the lists removes it from the iPhone only, like deleting its tab on a Mac.

If YANA can't open a list's sync folder, the list says **Not syncing** in your lists, and says when it last synced at
the top of the list. Removing the folder in Settings and adding it again usually fixes it.

## Undo, and Recently Deleted

Swipe a task away, or clear the checked ones, and **Undo** shows at the bottom for a few seconds. It puts the tasks
back where they were, on your other devices too.

A list you delete stays in **Recently Deleted**, at the bottom of your lists, for 30 days. **Put Back** makes it a
list again. A list that synced comes back on this iPhone only: to sync it again, bring it over from its folder in
Settings, or choose **Sync This List…**.

A list is named after its first task until you name it: choose **Rename…** from its **…** menu, or touch and hold it
in your lists. Leave the name empty to go back. The name syncs both ways with your Macs (on YANA 1.8 or later).

## How it's built

The app is SwiftUI, for iOS 17 or later, in `iOS/`. There's no Xcode project in the repo: `iOS/project.yml` describes
it, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) makes `iOS/YANA.xcodeproj` from it:

```sh
brew install xcodegen
cd iOS && xcodegen generate && open YANA.xcodeproj
```

It compiles the Mac app's `Note.swift`, `SyncFormat.swift` and `SyncPass.swift` too, so both apps read, write and merge
exactly the same files the same way. The code notes are in [AGENTS.md](../AGENTS.md).
