<p align="center"><img src="docs/icon.png" width="128" alt="YANA icon"></p>

<h1 align="center">YANA</h1>

<p align="center">Yet Another Notes App: one quick note that lives in your Mac's menu bar.</p>

<p align="center"><a href="https://github.com/jfreema/Yet-Another-Notes-App/raw/main/downloads/YANA.zip"><b>Download YANA</b></a></p>

<p align="center">Version 1.0.0 · macOS 14 or later · Apple silicon or Intel</p>

## Install

1. Open the **YANA.zip** you downloaded. It unzips to **YANA.app**.
2. Drag **YANA.app** into your **Applications** folder, then open it. Its note icon appears in the menu bar.
3. If macOS says it can't check YANA for malicious software, click **Done**, then **Open Anyway** in **System Settings → Privacy & Security**. Releases signed with YANA's Developer ID open without this step.
4. Right-click YANA in the menu bar and turn on **Open at Login**.

## Use it

- **Click the icon** in the menu bar to show your note, and click it again to put it away. Whatever you type is saved as you go.
- **Click the ×** (or press ⌘W) and the note goes back to the menu bar. Nothing is lost.
- **Keep on top:** click the pin at the top right of the note, and it stays above other windows. Unpinned, it falls behind whatever window you click next.
- **Transparency:** drag the slider at the top right of the note to see through it.
- **Text size:** ⌘+ and ⌘- make the text bigger and smaller, and ⌘0 puts it back.
- **Find:** ⌘F searches the note.
- **Options:** right-click the menu bar icon, or click **…** on the note, for **Keep on Top**, **Open at Login**, **About YANA**, **Check for Updates…** and **Quit YANA**.

The note is plain text, kept in `~/Library/Application Support/YANA/Note.txt`.

## Updates

Choose **Check for Updates…**. If there's a newer version, YANA downloads it from this repo, checks it, replaces itself in place and restarts. Your note and settings stay as they are.

## For developers

See [AGENTS.md](AGENTS.md) for building, and [docs/signing.md](docs/signing.md) for signing and notarizing releases.
