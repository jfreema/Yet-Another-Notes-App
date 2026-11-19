# Agents

Notes for any coding agent working on YANA.

## What YANA is

A macOS menu bar app with up to four tabs of plain-text notes and to-do lists, which can sync to-do lists with YANA on
other Macs. Clicking the menu bar icon shows the
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
| Keyboard shortcuts (new tab, convert to list, open and save .txt, Edit, Find, text size, ⌘1–⌘4, ⌘W) | `MainMenu` |
| The note window: tabs, pin, transparency slider, sticky note mode, converting a note to a list, opening and saving .txt files | `NoteWindow` |
| The tab strip | `TabBar` |
| A text tab, and how tabs look (`Look`: font and colors, sticky or not) | `Pages` |
| A text tab's line numbers (an `NSRulerView`) | `LineNumbers` |
| A to-do list tab, its rows, their numbers, and dragging them | `TodoList` |
| What a tab holds, and the change times a synced list keeps (`Note.stamped`) | `Note` |
| Syncing lists: the sync folders and their files, merging copies, this Mac's id | `SyncModel` |
| Syncing lists: reading the folders every few seconds, merging, and adding or taking away tabs | `ListSync` |
| Sync This List…: the folder and the devices a list goes to | `SyncSheet` |
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
- **Return in a task opens a new one next to it** (`TodoList.control(_:textView:doCommandBy:)`, splitting at the cursor
  with `ToDo.split`), and editing it waits a turn for the field editor to finish the Return. A task left empty is
  deleted when its editing ends, and Return in an empty task goes to adding one at the bottom.
- **Clear Checked** is a row under the add-a-task row, shown only while some tasks are checked (`TodoList.clearChecked`,
  also in the **…** menu). It registers an undo that puts the tasks back at their old places in the stack.
- **Deleting a task waits a turn** (`perform(_:with:afterDelay:)`), since its × or text is still handling the event.
- **Converting a note to a list swaps the tab's page** and registers an undo that swaps it back. That's why
  `select(_:keepingUndo:)` exists: selecting a tab otherwise clears the undo stack, which would wipe the redo.
- **Line numbers are a ruler.** Since macOS 14 views don't clip to their bounds, so the ruler and the scroll view's
  clip view set `clipsToBounds`, or the text view's background paints over the numbers. A list has no text view, so
  each `ToDoRow` has its own number label instead, sized and colored from the same `Look` values as the ruler.
- **Sticky note mode forces the light appearance** on the window, so dark mode doesn't fight the yellow.
- **1.0 kept one note in `Note.txt`.** `NoteStore` turns it into the first tab when there's no `Notes.json`, and
  leaves the file where it is.
- **Activation:** since macOS 14, `NSApp.activate()` is a request macOS can turn down, so alerts and the About panel
  use `NSApp.activateRegardless()`.

## Syncing

- **Each device only writes its own files.** A sync folder holds `devices/<device id>.json` and
  `lists/<list id>/<device id>.json`. Nothing writes another device's file, so iCloud Drive never makes conflicted
  copies. Files not named `<uuid>.json` are ignored.
- **Every note and task has an id** (`Note.id`, `ToDo.id`), given on load to notes from before 1.7. `ToDo.split` keeps
  the first half's id.
- **Change times come from comparing**, not from the UI. `ListSync.note(of:)` compares a synced list's page with the
  copy it last knew (`Note.stamped(since:at:)`): new or edited tasks get the time, missing ones become deletions, and a
  different order stamps `orderChanged`. So any edit, undo or drag is covered without hooks in `TodoList`.
- **The merge** (`SyncMerge.merge`) is per task, latest change wins, a deletion wins over an older change, the order
  comes from the latest copy to change it, and only devices still on the list count. It's pure, so it's what the tests
  cover.
- **Other devices' changes wait while you edit or drag a task** (`TodoList.isBusy`), then `TodoList.show(_:)` rebuilds
  the rows and clears that list's undo.
- **Starting to sync gives the list a new id**, so files left from an earlier time it synced don't mix in. Stopping
  writes an empty copy without this Mac in its devices; being taken off by another device deletes this Mac's copy.
- **Reading and writing is in the `SyncFiles` actor**, off the main thread, since a file in iCloud Drive may have to
  download first.

## Releasing

Every change users get raises `CFBundleShortVersionString` in `Resources/Info.plist`: the last number for fixes, the
middle one for a new feature. Pushing that to main runs the Release workflow, which builds, signs, notarizes and
commits `downloads/YANA.zip` and `downloads/latest.json`, where Check for Updates looks. Leave `downloads/` to the
workflow. Signing is in [docs/signing.md](docs/signing.md).
