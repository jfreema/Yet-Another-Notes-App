import AppKit

/// YANA has no menu bar of its own while the note is open, but these give the note its keyboard shortcuts
@MainActor
enum MainMenu {
    static func make(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "YANA")
        app.addItem(item("About YANA", #selector(AppDelegate.showAbout), target: target))
        app.addItem(item("Check for Updates…", #selector(AppDelegate.checkForUpdates), target: target))
        app.addItem(.separator())
        app.addItem(item("Quit YANA", #selector(AppDelegate.quit), "q", target: target))

        let file = submenu(main, "File")
        file.addItem(item("New Note", #selector(AppDelegate.newNote), "n", target: target))
        file.addItem(item("New To-Do List", #selector(AppDelegate.newList), "n", [.command, .shift], target: target))
        file.addItem(.separator())
        file.addItem(item("Open Text File…", #selector(AppDelegate.openTextFile), "o", target: target))
        file.addItem(item("Save as Text File…", #selector(AppDelegate.saveTextFile), "s", target: target))

        let edit = submenu(main, "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)
        let actions: [(String, String, NSEvent.ModifierFlags, NSTextFinder.Action)] = [
            ("Find…", "f", .command, .showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString),
        ]
        for (title, key, modifiers, action) in actions {
            let findAction = item(title, #selector(NSTextView.performFindPanelAction(_:)), key, modifiers)
            findAction.tag = action.rawValue
            find.addItem(findAction)
        }

        let view = submenu(main, "View")
        view.addItem(item("Bigger Text", #selector(AppDelegate.biggerText), "+", target: target))
        view.addItem(item("Smaller Text", #selector(AppDelegate.smallerText), "-", target: target))
        view.addItem(item("Actual Size", #selector(AppDelegate.actualSizeText), "0", target: target))

        let window = submenu(main, "Window")
        window.addItem(item("Keep on Top", #selector(AppDelegate.togglePinned), "t", [.command, .option], target: target))
        window.addItem(.separator())
        // ⌘1 to ⌘4 go to the tabs
        for number in 1...Note.limit {
            let tab = item("Note \(number)", #selector(AppDelegate.showTab(_:)), "\(number)", target: target)
            tab.tag = number - 1
            window.addItem(tab)
        }
        window.addItem(.separator())
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
