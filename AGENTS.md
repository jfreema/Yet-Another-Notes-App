# Agents

Notes for any coding agent working on YANA.

## What YANA is

A macOS menu bar app with one plain-text note. Clicking the menu bar icon shows the note, and closing it hides it back
to the menu bar. The note can be kept on top, and a slider sets its transparency. It's Swift with SwiftPM, with no Xcode
project and no third-party dependencies, for macOS 14 or later on Apple silicon or Intel. It's an accessory app
(`LSUIElement`), with no Dock icon. [README.md](README.md) is the user guide.

## Build and test

```sh
swift build            # compile
swift test             # unit tests (Swift Testing)
./build.sh             # build/YANA.app
./build.sh --install   # replace /Applications/YANA.app and open it
./build.sh --release   # universal, signed, zipped to downloads/ (CI does this)
```

Everything must build with the Command Line Tools alone, without Xcode.

## Code

| Area | Files |
|---|---|
| Launch, one copy at a time | `YANA` |
| Menu bar icon, its menu, About, Open at Login | `AppDelegate` |
| Keyboard shortcuts (Edit, Find, text size, ⌘W) | `MainMenu` |
| The note window, pin and transparency slider | `NoteWindow` |
| Saving the note | `NoteStore` |
| Check for Updates | `Updater` |

## Things that bite

- **Closing the note hides it.** `windowShouldClose` orders it out and hides the app, so focus goes back to the app you
  were in.
- **Keep on Top** is the window's level (`.floating`). Unpinned it's `.normal`, so it falls behind the next window
  clicked.
- **An accessory app still needs a main menu** for ⌘C, ⌘V, ⌘Z and the rest to work in the note.
- **Activation:** since macOS 14, `NSApp.activate()` is a request macOS can turn down, so alerts and the About panel
  use `NSApp.activateRegardless()`.

## Releasing

Every change users get raises `CFBundleShortVersionString` in `Resources/Info.plist`: the last number for fixes, the
middle one for a new feature. Pushing that to main runs the Release workflow, which builds, signs, notarizes and
commits `downloads/YANA.zip` and `downloads/latest.json`, where Check for Updates looks. Leave `downloads/` to the
workflow. Signing is in [docs/signing.md](docs/signing.md).
