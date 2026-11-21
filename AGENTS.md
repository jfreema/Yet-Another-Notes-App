# Agents

Notes for any coding agent working on YANA.

## What YANA is

A macOS menu bar app with up to four tabs of plain-text notes and to-do lists, which can sync to-do lists with YANA on
other Macs and YANA for iPhone (see [YANA for iPhone](#yana-for-iphone)), which also lives in this repo. Clicking the menu bar icon shows the
note window, and closing it hides it back to the menu bar. ⌃⌥N shows and hides it from any app. The window can be
kept on top, a slider sets its transparency, and sticky note mode makes it post-it yellow. It's Swift with SwiftPM,
with no Xcode project and no third-party dependencies, for macOS 14 or later on Apple silicon or Intel. It's an
accessory app (`LSUIElement`), with no Dock icon. [README.md](README.md) is the user guide.

## Build and test

```sh
swift build            # compile
swift test             # unit tests (Swift Testing)
./build.sh             # build/YANA.app
./build.sh --install   # replace /Applications/YANA.app and open it
./build.sh --release   # universal, signed, zipped to downloads/ (CI does this)
```

The Mac app must build with the Command Line Tools alone, without Xcode. YANA for iPhone needs Xcode.

## Code

| Area | Files |
|---|---|
| Launch, one copy at a time | `YANA` |
| Menu bar icon, its menu, About, Open at Login | `AppDelegate` |
| ⌃⌥N, the shortcut that shows and hides the note from any app | `HotKey` |
| Keyboard shortcuts (new tab, convert to list, open and save .txt, Edit, Find, text size, ⌘1–⌘4, ⌘W) | `MainMenu` |
| The note window: tabs, pin, transparency slider, sticky note mode, converting a note to a list, opening and saving .txt files | `NoteWindow` |
| The tab strip | `TabBar` |
| A text tab, and how tabs look (`Look`: font and colors, sticky or not) | `Pages` |
| A text tab's line numbers (an `NSRulerView`) | `LineNumbers` |
| A to-do list tab, its rows, their numbers, and dragging them | `TodoList` |
| What a tab holds, and the change times a synced list keeps (`Note.stamped`) | `Note` |
| Syncing lists: what's in a sync folder, and merging copies (shared with YANA for iPhone) | `SyncFormat` |
| Syncing lists: the sync folders this Mac uses, this Mac's id | `SyncModel` |
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
- **A text file opens as a list when it reads like one** (`Note.opened(fromText:file:)`): every line with something
  on it starts `[ ] ` or `[x] `, which is how `plainText` writes a list. Anything else opens as a note, so a file is
  never rewritten in another shape by Save. Converting a note to a list is looser (`tasks(fromText:)` takes any line).
- **Line numbers are a ruler.** Since macOS 14 views don't clip to their bounds, so the ruler and the scroll view's
  clip view set `clipsToBounds`, or the text view's background paints over the numbers. A list has no text view, so
  each `ToDoRow` has its own number label instead, sized and colored from the same `Look` values as the ruler.
- **A tab's name is `Note.name`, else what's in it** (`Note.title`, `contentsTitle`). Rename… (tab right-click, a
  double-click on a tab via `TabButton`, or the **…** menu) sets it with an alert sheet and registers an undo; an empty
  name takes it off. The tab bar also shows for a single tab once it has a name, since otherwise the name shows
  nowhere.
- **Sticky note mode forces the light appearance** on the window, so dark mode doesn't fight the yellow.
- **1.0 kept one note in `Note.txt`.** `NoteStore` turns it into the first tab when there's no `Notes.json`, and
  leaves the file where it is.
- **⌃⌥N is a Carbon hot key** (`RegisterEventHotKey`), the one system-wide shortcut that needs no permission: an
  event tap or a global `NSEvent` monitor would have YANA ask for Accessibility or Input Monitoring. It does what a
  click on the menu bar icon does (`NoteWindowController.toggle`), and **Show and Hide with ⌃⌥N** in the menu turns
  it off (`HotKey.isOn`, on until then). macOS turns the keys down when it has them itself (`isRegistered`): the menu
  item is then unticked, and choosing it says why. Another app can take the same keys too, and then both hear them.
  Since macOS 15 a hot key's modifiers can't be only Option or Shift, so keep Control or Command in it.
- **`HotKeyTests` take other keys than ⌃⌥N**, one set per test, since an app can't take the same keys twice and a
  YANA that's open has ⌃⌥N. `YANA_PRESS_KEYS=1 swift test` also presses ⌃⌥N for real with System Events, on a Mac
  that lets scripts type.
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
- **A list's name syncs like the order does**: `SyncedList.name` plus `nameChanged` (kept in `SyncInfo.nameChanged`),
  stamped by `stamped(since:at:)` when the name differs, and the copy with the latest `nameChanged` wins. Starting to
  sync a named list stamps it. Both fields are optional and left out of the file when nil, so 1.7 (and the first
  iPhone builds) read and write copies as before: a copy without `nameChanged` never changes the name.
- **New fields in a copy have to be optional.** Older versions skip keys they don't know, and `format` isn't checked,
  so a change that older versions can't skip would need a new folder layout, not just a new field.
- **Other devices' changes show at once, cursor in a task or not.** `TodoList.show(_:)` keeps the row of every task
  that's still there, so the one being edited keeps its cursor and what's typed, unless another device changed or
  deleted that very task. Empty tasks just opened stay where they are (`[ToDo].showing`), since they aren't synced.
  It clears that list's undo. Only a click or drag in progress makes changes wait (`TodoList.isDragging`), and never
  for long. 1.7.0 made them wait for any task being edited, and skipped writing this Mac's copy while they waited, so
  a cursor left in a task stopped that Mac syncing either way.
- **A sync runs every 3 seconds, right after a save, and when the note is shown or hidden** (`ListSync.run`). The
  timer alone can be slowed by App Nap while the note is hidden.
- **This Mac's copy is written whenever the folder's doesn't match**, and again every 15 seconds for as long as it
  still doesn't (`ListSync.writeSettles`), which covers a write that failed.
- **`ListSyncTests` sync a real `TodoList` through a folder**, with the other device's copies written by hand
  (`ListSync.pass()` is one awaited pass, and `ListSync.folders` gives it the test's folder). They put the cursor in
  a task with `makeFirstResponder`, which works on the runner without showing the window.
- **Starting to sync gives the list a new id**, so files left from an earlier time it synced don't mix in. Stopping
  writes an empty copy without this Mac in its devices; being taken off by another device deletes this Mac's copy.
  That empty copy is what keeps a list whose tab was deleted from coming back: finding lists in a folder counts this
  Mac's own copy too, and `ListSync.left` covers the moment before the copy is written.
- **Reading and writing is in the `SyncFiles` actor**, off the main thread, since a file in iCloud Drive may have to
  download first. Every copy is read every time: a modification date can't tell whether one changed, since a sync
  service may keep dates only to the second.
- **Sync Settings says when each device was last heard from**: the modification date of its copy of the list, which
  it writes whenever it has a change to pass on. It's the first thing to look at when two Macs don't agree.

## YANA for iPhone

`iOS/` is YANA for iPhone: SwiftUI, iOS 17 or later, iPhone only, bundle id `io.github.jfreema.yana.ios`. It shows and
edits synced to-do lists (no notes) and syncs them through the same folders. There's no Xcode project in the repo:
`cd iOS && xcodegen generate` makes `YANA.xcodeproj` from `project.yml`. [docs/iphone.md](docs/iphone.md) is its
setup and user guide.

| Area | Files |
|---|---|
| Launch, and syncing as YANA comes and goes | `YANAApp`, `AppModel.became` |
| The lists, the folders, this iPhone's id and name, saving to `Lists.json` | `AppModel` |
| Editing a list: Return in a task, empty tasks, change times | `Note+Phone` |
| Syncing: the same passes as `ListSync` on the Mac | `PhoneSync` |
| Reading and writing the folders, iCloud Drive downloads | `PhoneFiles` |
| A sync folder: its bookmark, and its paths | `Folders` |
| The screens | `ListsView`, `ListView`, `SyncSettingsView`, `SettingsView`, `Look` |

- **It compiles `Sources/YANA/Note.swift` and `Sources/YANA/SyncFormat.swift`** from the Mac app, so both apps write
  and merge the same files. Keep those two files to Foundation. A change to them runs the iPhone workflow, which runs
  the Mac's tests too.
- **A sync folder is a security-scoped bookmark**, picked with `fileImporter`. YANA has no iCloud entitlement: it
  uses the folder you picked in Files, so a folder shared from another Apple ID works the same as YANA Sync.
- **iCloud Drive may not have downloaded a file yet.** iOS lists one of those as `.<name>.icloud`; `PhoneFiles` asks
  for it and reads it on a later pass, rather than waiting. One that's out of date is asked for and read as it is.
- **Empty tasks aren't saved or synced**, as on the Mac. `Note.syncable` leaves them out, `Note.stamped(after:at:)`
  stamps a change made here without counting them, and `[ToDo].showing` keeps them in place when a merge comes in.
- **Return arrives as a new line in a task's text** (its `TextField` is vertical so long tasks wrap). `Note.enter`
  turns it into a new task the way Return works on the Mac.
- **Starting to sync gives the list a new id**, as on the Mac. `AppModel` remembers the old id, so the list's screen
  keeps showing it.
- **It syncs only while open**: every 3 seconds, soon after a change, and once more as it goes to the background.
- **Release**: the iPhone workflow tests on the simulator, archives unsigned, and on main exports with cloud signing
  and uploads to TestFlight, using the App Store Connect API key in `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY`. The
  build number is the run number. The version is `CFBundleShortVersionString` in `iOS/Info.plist`.

## Releasing

Every change users get raises `CFBundleShortVersionString` in `Resources/Info.plist`: the last number for fixes, the
middle one for a new feature. Pushing that to main runs the Release workflow, which builds, signs, notarizes and
commits `downloads/YANA.zip` and `downloads/latest.json`, where Check for Updates looks. Leave `downloads/` to the
workflow. Signing is in [docs/signing.md](docs/signing.md).
