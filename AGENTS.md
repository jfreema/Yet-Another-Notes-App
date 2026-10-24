# Agents

Notes for any coding agent working on YANA.

## What YANA is

A macOS menu bar app with up to four tabs of plain-text notes and to-do lists. Clicking the menu bar icon shows the
note window, and closing it hides it back to the menu bar. The window can be kept on top, a slider sets its
transparency, and sticky note mode makes it post-it yellow. It's Swift with SwiftPM, with no Xcode
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
| Keyboard shortcuts (new tab, open and save .txt, Edit, Find, text size, ⌘1–⌘4, ⌘W) | `MainMenu` |
| The note window: tabs, pin, transparency slider, sticky note mode, opening and saving .txt files | `NoteWindow` |
| The tab strip | `TabBar` |
| A text tab, and how tabs look (`Look`: font and colors, sticky or not) | `Pages` |
| A text tab's line numbers (an `NSRulerView`) | `LineNumbers` |
| A to-do list tab, its rows, and dragging them | `TodoList` |
| What a tab holds | `Note` |
| Saving the notes to `Notes.json` | `NoteStore` |
| Check for Updates | `Updater` |

## Things that bite

- **Closing the note hides it.** `windowShouldClose` orders it out and hides the app, so focus goes back to the app you
  were in.
- **Keep on Top** is the window's level (`.floating`). Unpinned it's `.normal`, so it falls behind the next window
  clicked.
- **An accessory app still needs a main menu** for ⌘C, ⌘V, ⌘Z and the rest to work in the note.
- **A task's text doesn't take a click until it's being edited.** `ToDoRow.hitTest` sends the click to the row, and
  `TodoList.track` turns it into editing on mouse up, or a drag once the mouse moves.
- **Deleting a task waits a turn** (`perform(_:with:afterDelay:)`), since its × or text is still handling the event.
- **Line numbers are a ruler.** Since macOS 14 views don't clip to their bounds, so the ruler and the scroll view's
  clip view set `clipsToBounds`, or the text view's background paints over the numbers.
- **Sticky note mode forces the light appearance** on the window, so dark mode doesn't fight the yellow.
- **1.0 kept one note in `Note.txt`.** `NoteStore` turns it into the first tab when there's no `Notes.json`, and
  leaves the file where it is.
- **Activation:** since macOS 14, `NSApp.activate()` is a request macOS can turn down, so alerts and the About panel
  use `NSApp.activateRegardless()`.

## Releasing

Every change users get raises `CFBundleShortVersionString` in `Resources/Info.plist`: the last number for fixes, the
middle one for a new feature. Pushing that to main runs the Release workflow, which builds, signs, notarizes and
commits `downloads/YANA.zip` and `downloads/latest.json`, where Check for Updates looks. Leave `downloads/` to the
workflow. Signing is in [docs/signing.md](docs/signing.md).
