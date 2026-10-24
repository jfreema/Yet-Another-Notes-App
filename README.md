<p align="center"><img src="docs/icon.png" width="128" alt="YANA icon"></p>

<h1 align="center">YANA</h1>

<p align="center">Yet Another Notes App: quick notes and to-do lists that live in your Mac's menu bar.</p>

<p align="center"><a href="https://github.com/jfreema/Yet-Another-Notes-App/raw/main/downloads/YANA.zip"><b>Download YANA</b></a></p>

<p align="center">Version 1.2.0 · macOS 14 or later · Apple silicon or Intel</p>

## Install

1. Open the **YANA.zip** you downloaded. It unzips to **YANA.app**.
2. Drag **YANA.app** into your **Applications** folder, then open it. Its note icon appears in the menu bar.
3. If macOS says it can't check YANA for malicious software, click **Done**, then **Open Anyway** in **System Settings → Privacy & Security**. Releases signed with YANA's Developer ID open without this step.
4. Right-click YANA in the menu bar and turn on **Open at Login**.

## Use it

- **Click the icon** in the menu bar to show your note, and click it again to put it away. Whatever you type is saved as you go.
- **Click the ×** (or press ⌘W) and the note goes back to the menu bar. Nothing is lost.
- **Tabs:** click **+** at the top right for a new note or to-do list, up to four. The tabs show once there's more than one, named for what's at the top of each. Right-click a tab to delete it. ⌘1 to ⌘4 switch tabs, and ⌘N and ⇧⌘N add a note or a list.
- **Line numbers** run down the left side of a note, with the line you're on in bold. To-do lists don't have them.
- **Text files:** **Open Text File…** (⌘O) in the **…** menu brings a .txt file into a new tab, or into the tab you're on if it's empty. **Save as Text File…** (⌘S) saves the tab you're on as a .txt file, a to-do list one task to a line. Neither keeps the file linked: later edits stay in YANA.
- **To-do lists:** type a task in the last row and press Return. Check it off and it's crossed out, with an × beside it that deletes it. Check it again to bring it back. Click a task to edit it, or drag it up or down to put it where you want.
- **Sticky note mode:** turn it on in the **…** menu for post-it yellow with black, hand-lettered text.
- **Keep on top:** click the pin at the top right of the note, and it stays above other windows. Unpinned, it falls behind whatever window you click next.
- **Transparency:** drag the slider at the top right of the note to see through it.
- **Text size:** ⌘+ and ⌘- make the text bigger and smaller, and ⌘0 puts it back.
- **Find:** ⌘F searches a note.
- **Options:** right-click the menu bar icon, or click **…** on the note, for **Keep on Top**, **Sticky Note Mode**, **Open Text File…**, **Save as Text File…**, **Open at Login**, **About YANA**, **Check for Updates…** and **Quit YANA**.

Your notes are kept in `~/Library/Application Support/YANA/Notes.json`.

## Updates

Choose **Check for Updates…**. If there's a newer version, YANA downloads it from this repo, checks it, replaces itself in place and restarts. Your notes and settings stay as they are.

## For developers

See [AGENTS.md](AGENTS.md) for building, and [docs/signing.md](docs/signing.md) for signing and notarizing releases.
