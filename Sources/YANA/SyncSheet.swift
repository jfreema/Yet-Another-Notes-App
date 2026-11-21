import AppKit

/// Sync List…: the folder a to-do list syncs through, and which of your devices it goes to
@MainActor
final class SyncSheet: NSObject {
    enum Choice {
        case sync(SyncFolder, devices: [String])
        case stop
    }

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 240), styleMask: [.titled],
                                backing: .buffered, defer: true)
    private let content = NSStackView()
    private let folderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let devicesStack = NSStackView()
    private var boxes: [(id: String, box: NSButton)] = []
    private var shownDevices: Set<String> = []
    private let list: UUID
    private let current: SyncInfo?
    /// When the list last synced, if it has stopped
    private let lastSynced: Date?
    private var onChoice: ((Choice?) -> Void)?
    private weak var parent: NSWindow?
    /// The folder picked before Choose Another Folder…, to go back to if that's cancelled
    private var lastFolderIndex = 0

    private static let suggestedTag = -1
    private static let chooseTag = -2
    private static let width: CGFloat = 340

    init(listTitle: String, list: UUID, current: SyncInfo?, lastSynced: Date? = nil) {
        self.list = list
        self.current = current
        self.lastSynced = lastSynced
        super.init()

        let heading = NSTextField(labelWithString: current == nil ? "Sync “\(listTitle)”"
            : "Sync Settings for “\(listTitle)”")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        heading.lineBreakMode = .byTruncatingTail

        let about = NSTextField(wrappingLabelWithString: current == nil
            ? "The list syncs through a folder your devices can reach, like one in iCloud Drive or one you've shared with your other Apple ID. Each device shows up here once YANA on it adds the folder."
            : "Changes to the list sync with the devices ticked here. Unticking one takes the list off it.")
        about.preferredMaxLayoutWidth = Self.width
        about.textColor = .secondaryLabelColor
        about.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        folderPopup.target = self
        folderPopup.action = #selector(folderChanged)
        folderPopup.isEnabled = current == nil
        let folderRow = NSStackView(views: [NSTextField(labelWithString: "Folder:"), folderPopup])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8

        devicesStack.orientation = .vertical
        devicesStack.alignment = .leading
        devicesStack.spacing = 6

        let stop = NSButton(title: "Stop Syncing", target: self, action: #selector(stopClicked))
        stop.isHidden = current == nil
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: current == nil ? "Sync" : "Done", target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [stop, spacer, cancel, done])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false
        for view in [heading, about, folderRow, NSTextField(labelWithString: "Send it to:"), devicesStack, buttons] {
            content.addArrangedSubview(view)
        }
        content.setCustomSpacing(16, after: devicesStack)
        NSLayoutConstraint.activate([
            buttons.widthAnchor.constraint(equalToConstant: Self.width),
            heading.widthAnchor.constraint(lessThanOrEqualToConstant: Self.width),
            folderPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container

        fillFolders(selecting: current?.folder ?? SyncFolders.all.first?.id)
        showDevices()
    }

    func begin(for window: NSWindow, then onChoice: @escaping (Choice?) -> Void) {
        self.onChoice = onChoice
        parent = window
        fit()
        window.beginSheet(panel) { _ in }
    }

    private func finish(_ choice: Choice?) {
        parent?.endSheet(panel)
        panel.orderOut(nil)
        let onChoice = self.onChoice
        self.onChoice = nil
        onChoice?(choice)
    }

    private func fit() {
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(content.fittingSize)
    }

    // MARK: Folders

    private func fillFolders(selecting id: String?) {
        let menu = NSMenu()
        let folders = SyncFolders.all
        for folder in folders {
            let item = NSMenuItem(title: "\(folder.name) (\(folder.place))", action: nil, keyEquivalent: "")
            item.representedObject = folder.id
            menu.addItem(item)
        }
        // YANA Sync in iCloud Drive, made when you first sync to it
        let suggested = SyncFolders.suggested.standardizedFileURL
        if SyncFolders.hasICloudDrive && !folders.contains(where: { $0.url.standardizedFileURL == suggested }) {
            let item = NSMenuItem(title: "YANA Sync (iCloud Drive)", action: nil, keyEquivalent: "")
            item.tag = Self.suggestedTag
            menu.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let choose = NSMenuItem(title: "Choose Another Folder…", action: nil, keyEquivalent: "")
        choose.tag = Self.chooseTag
        menu.addItem(choose)
        folderPopup.menu = menu

        let index = menu.items.firstIndex { id != nil && ($0.representedObject as? String) == id } ?? 0
        folderPopup.selectItem(at: index)
        lastFolderIndex = index
    }

    /// The folder picked, if it's one YANA already uses
    private var pickedFolder: SyncFolder? {
        guard let id = folderPopup.selectedItem?.representedObject as? String else { return nil }
        return SyncFolders.folder(id)
    }

    @objc private func folderChanged(_ sender: NSPopUpButton) {
        guard sender.selectedItem?.tag == Self.chooseTag else {
            lastFolderIndex = sender.indexOfSelectedItem
            showDevices()
            return
        }
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.allowsMultipleSelection = false
        open.prompt = "Use Folder"
        open.message = "Choose a folder your other devices can reach, such as one in iCloud Drive or Dropbox"
        open.directoryURL = SyncFolders.hasICloudDrive ? SyncFolders.iCloudDrive : nil
        open.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard response == .OK, let url = open.url else {
                    self.folderPopup.selectItem(at: self.lastFolderIndex)
                    return
                }
                do {
                    let folder = try SyncFolders.add(url)
                    self.fillFolders(selecting: folder.id)
                } catch {
                    self.folderPopup.selectItem(at: self.lastFolderIndex)
                    Alert.show("Couldn't use “\(url.lastPathComponent)”", error.localizedDescription)
                }
                self.showDevices()
            }
        }
    }

    // MARK: Devices

    private func showDevices() {
        devicesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        boxes = []
        let me = NSButton(checkboxWithTitle: "This Mac (\(ThisDevice.name))", target: nil, action: nil)
        me.state = .on
        me.isEnabled = false
        devicesStack.addArrangedSubview(me)

        // Said here, since nothing else shows that a folder has stopped working
        if let folder = pickedFolder, !folder.canBeRead {
            var problem = "YANA can't open this folder, so nothing syncs through it. Check that it's still there, and that YANA is allowed to use it in System Settings › Privacy & Security › Files and Folders."
            if let lastSynced, folder.id == current?.folder {
                problem += " The list last synced \(min(lastSynced, Date()).formatted(.relative(presentation: .named)))."
            }
            let warning = NSTextField(wrappingLabelWithString: problem)
            warning.preferredMaxLayoutWidth = Self.width - 20
            warning.textColor = .systemRed
            warning.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            devicesStack.addArrangedSubview(warning)
            // The devices it goes to now all stay
            shownDevices = []
            if panel.isVisible { fit() }
            return
        }

        let cards = (pickedFolder?.devices() ?? []).filter { $0.id != ThisDevice.id }
        shownDevices = Set(cards.map(\.id))
        for card in cards {
            let box = NSButton(checkboxWithTitle: card.name, target: nil, action: nil)
            box.state = current?.devices.contains(card.id) == true ? .on : .off
            box.toolTip = "Last seen \(card.seen.formatted(date: .abbreviated, time: .shortened))"
            devicesStack.addArrangedSubview(box)
            boxes.append((card.id, box))
            if let status = heard(from: card) {
                let label = NSTextField(labelWithString: status)
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                // Under the device's name, not its checkbox
                let row = NSStackView(views: [label])
                row.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
                devicesStack.setCustomSpacing(2, after: box)
                devicesStack.addArrangedSubview(row)
            }
        }
        if cards.isEmpty {
            let none = NSTextField(wrappingLabelWithString: "No other devices use this folder yet. On your other Mac, choose Add Sync Folder… in YANA's menu and pick this folder. It shows up here, and YANA on it offers to bring this list over.")
            none.preferredMaxLayoutWidth = Self.width - 20
            none.textColor = .secondaryLabelColor
            none.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            devicesStack.addArrangedSubview(none)
        }
        if panel.isVisible { fit() }
    }

    /// When a device the list already goes to last wrote its copy of it, which it does whenever it has a change to pass
    /// on. It tells whether that device's changes are reaching this Mac.
    private func heard(from card: DeviceCard) -> String? {
        guard let current = current, current.devices.contains(card.id), let folder = pickedFolder,
              folder.id == current.folder else { return nil }
        let file = folder.copy(of: list, by: card.id)
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "Hasn't picked up this list yet" }
        // Its clock may be a little ahead of this Mac's
        return "Last heard from \(min(date, Date()).formatted(.relative(presentation: .named)))"
    }

    // MARK: Buttons

    @objc private func doneClicked(_ sender: NSButton) {
        var folder = pickedFolder
        if folder == nil && folderPopup.selectedItem?.tag == Self.suggestedTag {
            do {
                folder = try SyncFolders.add(SyncFolders.suggested)
            } catch {
                Alert.show("Couldn't make the YANA Sync folder in iCloud Drive", error.localizedDescription)
                return
            }
        }
        guard let folder else {
            NSSound.beep()
            return
        }
        var devices = boxes.filter { $0.box.state == .on }.map { $0.id }
        // Devices it already goes to that aren't in this folder's list stay
        devices += (current?.devices ?? []).filter { $0 != ThisDevice.id && !shownDevices.contains($0) }
        finish(.sync(folder, devices: devices))
    }

    @objc private func stopClicked(_ sender: NSButton) {
        finish(.stop)
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        finish(nil)
    }
}
