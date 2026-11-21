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
| A text tab's line numbers (an `NSRulerView`), and where each line starts, kept up to date edit by edit | `LineNumbers`, `LineIndex` |
| A to-do list tab, its rows, their numbers, wrapping a long task, and dragging them | `TodoList` |
| What a tab holds, and the change times a synced list keeps (`Note.stamped`) | `Note` |
| Syncing lists: what's in a sync folder, what YANA takes from one (`SyncLimits`), and merging copies (shared with YANA for iPhone) | `SyncFormat` |
| Syncing lists: what one pass does with the lists here and the copies in the folders, where things are in a folder, and what to say when a list is taken off this device (shared with YANA for iPhone) | `SyncPass` |
| Syncing lists: the sync folders this Mac uses, this Mac's id | `SyncModel` |
| Syncing lists: reading the folders when they change, showing what `SyncPass` works out (adding or taking away tabs), whether each list is syncing, a folder's lists to bring here, noticing a new device, and the lists other devices took off this Mac | `ListSync` |
| Syncing lists: hearing when something changes in a sync folder (FSEvents) | `FolderWatcher` |
| Sync This List…: the folder and the devices a list goes to | `SyncSheet` |
| Saving the notes to `Notes.json`, and Recently Deleted | `NoteStore` |
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
  `TodoList.delete` then registers the same undo as Clear Checked. A task emptied to delete it comes back as it was
  when its editing began (`ToDoRow.textBefore`), and one that never had anything in it just goes.
- **A task's text wraps** (`TaskField`). Its `intrinsicContentSize` is the height its cell needs at the width it has,
  so a task's height follows from a layout pass that gave it a width, and settles on the pass after. Tests lay out
  more than once for that. While a task is edited, a copy of the cell measures what's in the field editor, so the
  editing isn't touched. The checkbox and number stay on the first line: `TaskField.fit(_:beside:)` pins the
  checkbox's middle to the text's first baseline, less half a capital's height (`firstLineCenter`).
- **Each tab has its own Undo** (`NotePage.undo`), so going to another tab loses none of it. The window gets the
  selected tab's from `windowWillReturnUndoManager`, a text tab's text view from `undoManager(for:)`, and a list
  overrides `undoManager`, which is what a task's field editor finds. **Converting a note to a list swaps the tab's
  page** and hands its Undo to the new page, with an undo that swaps it back. Deleting a tab clears its Undo, which
  otherwise holds on to the page.
- **Recently Deleted** is `Recently Deleted.json` beside `Notes.json` (`NoteStore.keepDeleted`). It gets a deleted
  tab's note or list, a list another device took off this Mac, and a tab replaced by an opened file. They're kept 30
  days, 50 at most, and the old ones go when it's read. Putting one back gives it a new id and no sync.
  `NoteWindowController.discard` is deleting without the alert, which is what the tests call: `show()` and alerts need
  the app running, so the tests stay clear of them.
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
- **Typing does as little as it can.** A keystroke retitles only its own tab (`NoteWindowController.noteChanged`,
  `TabBar.retitle`), and a text tab finds its title without copying the note out of the text view (`TextPage.title`,
  which has to match `Note.title`). The line numbers keep a `LineIndex` of where lines start, updated from the text
  storage's `editedRange` and `changeInLength`, so finding the cursor's line is a look-up and not a count from the top;
  it starts over if an edit doesn't fit. The notes are saved half a second after the last change, and `NoteStore.save`
  skips the write when the notes encode to what it last read or wrote, which it keeps in memory.
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
- **A sync folder isn't trusted.** Anything that can write to it can put a file there, and nothing signs a copy, so
  the aim is that no file can lose a list for good or lock one up, not that none can change one. Four things do it,
  all in the shared code so both apps have them:
  - *A file is only what its name says.* `SyncedList.read` and `DeviceCard.read` skip a copy or a card whose
    `device` or `id` isn't the device its file is named for, one past `SyncLimits` (4 MB or 5,000 tasks for a copy,
    16 KB for a card), and anything that doesn't decode. The readers check the size the file system gives before
    reading (`SyncLimits.fits`), so a huge file is never read. This device's own copy isn't held to the limits when
    it's written: a list that big would stop syncing without saying so, which no list of YANA's comes near.
  - *A date well ahead of this device's clock has no say* (`SyncMerge.clockSlack`, a day, so clocks set a few hours
    out sync as they always have). The latest change wins, so a copy dated next year used to win over every change
    until then, and a device taken off a list that way couldn't be put back. `SyncMerge.decide` now reads another
    device's copy `withoutFutureDates`: its devices, order and name lose to any other copy's, its deletions are left
    out, and its tasks lose to any other copy of them, though a task only it has still comes over, undated. This
    device's own copy is `restamped` instead, to now: its date was wrong when it made those changes, its user is
    looking at them, and dated now they reach the other devices. The same goes for a list it left
    (`ListSync.left`, the iPhone's `AppModel.left`) and for the copy saying it left, which `SyncPass.run` writes
    again. The cost: a device whose date is still more than a day ahead gets the others' changes, but its own
    changes to tasks they have don't reach them until its date is right or that day comes.
  - *A list taken off this device is kept, and it says so.* The tab or list goes, since unticking a device is how
    a list is taken off it, but what was here goes to Recently Deleted, and `SyncPass.Removal` says which device's
    copy did it. `ListSync.takenOff` (the iPhone's `AppModel.takenOff`) holds a `TakenOff` for each, named from the
    folder's cards and kept in UserDefaults (`syncTakenOff`) until it's been said. The Mac says it in a sheet the
    next time the note is showing with nothing over it (`NoteWindowController.showOffers`, before any offer), so
    YANA still never opens by itself. `[TakenOff].notice` words it for both apps.
  - *Lists sent here stop at a number* (`ListSync.mostTabs`, 20; `AppModel.mostLists`, 200), passed to
    `SyncPass.run` as `room`. The ones past it wait in the folder and come when there's room. Until 1.9.2 a list
    naming this Mac got a tab however many there were.
- **Other devices' changes show at once, cursor in a task or not.** `TodoList.show(_:)` keeps the row of every task
  that's still there, so the one being edited keeps its cursor and what's typed, unless another device changed or
  deleted that very task. Empty tasks just opened stay where they are (`[ToDo].showing`), since they aren't synced.
  It clears that list's undo. Only a click or drag in progress makes changes wait (`TodoList.isDragging`), and never
  for long. 1.7.0 made them wait for any task being edited, and skipped writing this Mac's copy while they waited, so
  a cursor left in a task stopped that Mac syncing either way.
- **A sync runs when a sync folder changes, right after a save, and when the note is shown or hidden**
  (`ListSync.run`). `FolderWatcher` is an FSEvents stream on the sync folders, which also reports what iCloud Drive
  brings in, with changes gathered for a second. This Mac's own writes are reported too, so each is followed by one
  pass that finds nothing to do. A pass also runs once a minute (`ListSync.readEvery`), in case a sync service
  changes a folder without the file system saying so. Until 1.9.1 it read every folder every 3 seconds.
- **What a pass does is in `SyncPass`**, which YANA for iPhone compiles too: given the synced lists here and every
  copy found in the folders, it gives back the lists to show, add and take away, and this device's copies to write
  and delete. It's pure (no files, no UI), so `SyncPassTests` cover it directly. `ListSync` and the iPhone's
  `PhoneSync` only read and write the files and hand the result to the window or the model. Keep it to Foundation.
- **A sync asked for while the folders are being read is followed by another** (`ListSync.again`), since what was
  read may be out of date by then. With the 3-second timer gone, nothing else would catch it for a minute.
- **This Mac's copy is written whenever the folder's doesn't match**, and again every 15 seconds for as long as it
  still doesn't (`ListSync.writeSettles`), which covers a write that failed.
- **`ListSyncTests` sync a real `TodoList` through a folder**, with the other device's copies written by hand
  (`ListSync.pass()` is one awaited pass, and `ListSync.folders` gives it the test's folder). They put the cursor in
  a task with `makeFirstResponder`, which works on the runner without showing the window.
- **Starting to sync gives the list a new id**, so files left from an earlier time it synced don't mix in. Stopping
  writes an empty copy without this Mac in its devices; being taken off by another device deletes this Mac's copy,
  keeps the list in Recently Deleted, and says so (see *A sync folder isn't trusted*).
  That empty copy is what keeps a list whose tab was deleted from coming back: finding lists in a folder counts this
  Mac's own copy too, and `ListSync.left` covers the moment before the copy is written. `left` is kept in
  UserDefaults (`syncLeft`) for as long as a deleted task is, so if an older copy of this Mac's lands late, after
  YANA has been reopened, the list still stays gone and its copy says again that it left.
- **Reading and writing is in the `SyncFiles` actor**, off the main thread, since a file in iCloud Drive may have to
  download first. Every copy is read every time: a modification date can't tell whether one changed, since a sync
  service may keep dates only to the second.
- **Sync Settings says when each device was last heard from**: the modification date of its copy of the list, which
  it writes whenever it has a change to pass on. It's the first thing to look at when two Macs don't agree.
- **A tab says when its list has stopped syncing.** `ListSync.state(of:)` is `.stopped` for a list whose folder
  couldn't be read on the last pass, or isn't one of this Mac's folders any more. The tab bar then shows an orange
  warning in place of the sync mark, with when it last synced, and `SyncHost.syncStateChanged` refreshes the tabs.
  When each folder was last read is kept in UserDefaults (`syncLastRead`), saved about once a minute.
- **Add Sync Folder shows the lists in the folder** that other devices sync and this Mac doesn't have
  (`ListSync.lists(in:)`), and `join` brings the ticked ones here: this Mac adds itself to their devices, with a
  `devicesChanged` later than the latest one, the same as ticking it on another device. Picking a folder YANA already
  uses shows them again, which is also how a list whose tab was deleted comes back.
- **A device that starts using a folder is noticed** by comparing the folder's device cards with the ones seen before
  (`syncKnownDevices` in UserDefaults, looked at every 30 seconds). The first look at a folder only remembers who's
  there. The window offers the new device the lists that sync through the folder (`SyncHost.offer`) the next time the
  note is showing with no sheet over it, so YANA never opens by itself.

## YANA for iPhone

`iOS/` is YANA for iPhone: SwiftUI, iOS 17 or later, iPhone only, bundle id `io.github.jfreema.yana.ios`. It shows and
edits synced to-do lists (no notes) and syncs them through the same folders. There's no Xcode project in the repo:
`cd iOS && xcodegen generate` makes `YANA.xcodeproj` from `project.yml`. [docs/iphone.md](docs/iphone.md) is its
setup and user guide.

| Area | Files |
|---|---|
| Launch, and syncing as YANA comes and goes | `YANAApp`, `AppModel.became` |
| The lists, the folders, this iPhone's id and name, saving to `Lists.json`, Recently Deleted, Undo for deleted tasks, whether a list is syncing, a new device to offer lists to, and the lists other devices took off this iPhone | `AppModel` |
| Editing a list: Return in a task, empty tasks, change times | `Note+Phone` |
| Syncing: reading the folders when they change, the same passes as the Mac (`SyncPass`), a folder's lists to bring here, joining them, and which device took a list off this iPhone | `PhoneSync` |
| Reading and writing the folders, iCloud Drive downloads, skipping files that aren't what their names say or are too big | `PhoneFiles` |
| A sync folder: its bookmark, and its paths | `Folders` |
| The screens | `ListsView`, `ListView`, `SyncSettingsView`, `SettingsView`, `FolderListsView`, `DeletedListsView`, `Look` |

- **It compiles `Sources/YANA/Note.swift`, `SyncFormat.swift` and `SyncPass.swift`** from the Mac app, so both apps
  write and merge the same files, and do the same thing on each pass. Keep those three files to Foundation. A change
  to them runs the iPhone workflow, which runs the Mac's tests too.
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
- **It syncs only while open**: when a sync folder changes, soon after a change here, and once more as it goes to
  the background. `PhoneSync` presents each sync folder to iOS (`FolderPresenter`, an `NSFilePresenter`) while YANA
  is open, which is how iOS says what iCloud Drive brought in; changes are gathered for most of a second. The
  presenters come off as YANA goes to the background, as iOS expects. Two things cover a change iOS doesn't report:
  a pass every 30 seconds (`readEvery`), and one every 3 seconds for as long as iCloud Drive is still bringing a file
  down (`PhoneFiles.askedForDownloads`). It used to read every folder every 3 seconds. The presenters can't be
  tried against the real iCloud Drive in the simulator, which is why the fallback is 30 seconds and not a minute.
- **Typing is saved after a pause**, not a character at a time: `AppModel.change(_:typing:)` marks it `unsaved`, and
  it's written with the sync that follows 0.6 seconds after the last character, by any other change, by Return making
  a task, and as YANA goes to the background.
- **The screens that show a folder read it again after each sync pass** (`AppModel.syncPasses`), not on a timer of
  their own.
- **Undo is one deletion deep.** `AppModel.undoable` holds the tasks last swiped away or cleared, with their places,
  and `ListView` shows the Undo bar for six seconds. Putting them back is an ordinary change, so in a synced list
  they're stamped later than their deletion and come back on the other devices too.
- **Recently Deleted is in `Lists.json`** (`Saved.deleted`, optional so older builds read the file). It gets a list
  deleted here and one another device took off this iPhone, as it was here and without its syncing, for 30 days, 50
  at most. Putting one back gives it a new id, as on the Mac.
- **A list another device takes off this iPhone is said in an alert** (`ListsView`, from `AppModel.takenOff`), over
  whatever screen is showing, with a button to Recently Deleted when something was kept. It's put on the
  `NavigationStack`, not the list of lists, so it shows over the list's own screen too, which by then only says
  List Removed. It waits for a sheet to close, and an offer to a new device waits for it. The model forgets them
  only once the alert is dismissed, so one that couldn't show is said the next time YANA opens.
- **Adding a folder shows its lists** (`FolderListsView`, from `PhoneSync.lists(in:)`), and `join` brings the ones
  switched on here the way the Mac's `ListSync.join` does. It reads the folder again after each sync pass while it's
  showing, since iCloud Drive may still be downloading what's in it. Tapping a folder in Settings shows them again.
- **A list says when it has stopped syncing** (`AppModel.syncProblem`): its folder's bookmark wouldn't open, or the
  folder couldn't be listed on the last pass. When each folder was last read is in UserDefaults (`syncLastRead`).
- **A device that starts using a folder is offered its lists** (`AppModel.noticed`, `DeviceOfferView`), as on the Mac.
  The first look at a folder counts every device listed there, downloaded yet or not, so a card that iCloud Drive
  brings down late isn't taken for a new device.
- **The sample lists don't sync** (`AppModel.isSample`). Their folder is a real one in the temporary directory, with
  a Mac's card and two of its lists, so the screens that read a folder have something to show.
- **The UI tests are tried up to three times** (`-retry-tests-on-failure`), since a tap or a drag on the hosted
  simulator sometimes misses: three of four runs on 2026-11-21 failed, each on a different UI test that passed the
  next time. The workflow says which tests needed another try, and shows where a failing one failed and what was on
  screen.
- **Release**: the iPhone workflow tests on the simulator, archives unsigned, and on main exports with cloud signing
  and uploads to TestFlight, using the App Store Connect API key in `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY`. The
  build number is the run number. The version is `CFBundleShortVersionString` in `iOS/Info.plist`.

## Releasing

Every change users get raises `CFBundleShortVersionString` in `Resources/Info.plist`: the last number for fixes, the
middle one for a new feature. Pushing that to main runs the Release workflow, which builds, signs and notarizes, then
publishes the zipped app as a GitHub Release (`v<version>`, with `YANA.zip` attached) and commits
`downloads/latest.json`, where Check for Updates looks. Its `url` is the release's zip, and every version of YANA
downloads whatever `url` says, so older ones keep updating. The README's Download link goes to the latest release's
`YANA.zip`. Leave `downloads/` to the workflow. The zip isn't committed any more: it was before 1.9, and those copies
are still in the history. Signing is in [docs/signing.md](docs/signing.md).
