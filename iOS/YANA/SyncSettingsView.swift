import SwiftUI
import UniformTypeIdentifiers

/// Sync This List… and Sync Settings…: the folder a list syncs through, and which of your devices it goes to. A
/// device shows up to tick once YANA on it has added the same folder.
struct SyncSettingsView: View {
    let listID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folderID: String?
    @State private var devices: [DeviceCard] = []
    @State private var heard: [String: Date] = [:]
    @State private var ticked: Set<String> = []
    @State private var loaded = false
    @State private var addingFolder = false
    @State private var confirmingStop = false
    @State private var problem: String?

    private var current: SyncInfo? { model.list(listID)?.sync }
    /// The other devices in the folder
    private var others: [DeviceCard] { devices.filter { $0.id != model.device } }

    var body: some View {
        NavigationStack {
            Form {
                folder
                sendTo
                if current != nil {
                    Section {
                        Button("Stop Syncing on This iPhone", role: .destructive) { confirmingStop = true }
                    } footer: {
                        Text("The list stays here and on your other devices, but changes stop going between them.")
                    }
                }
            }
            .navigationTitle(current == nil ? "Sync List" : "Sync Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(current == nil ? "Sync" : "Done", action: confirm)
                        .disabled(folderID == nil)
                }
            }
            .task(id: folderID) {
                await watchDevices()
            }
            .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
                let before = Set(model.folders.map(\.id))
                problem = model.addFolder(from: result)
                if let added = model.folders.first(where: { !before.contains($0.id) }) {
                    folderID = added.id
                }
            }
            .alert("Couldn't use that folder", isPresented: hasProblem) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
            .confirmationDialog("Stop syncing this list on this iPhone?", isPresented: $confirmingStop,
                                titleVisibility: .visible) {
                Button("Stop Syncing", role: .destructive) {
                    model.stopSyncing(listID)
                    dismiss()
                }
            }
        }
        .onAppear {
            folderID = current?.folder ?? model.folders.first?.id
            ticked = Set(current?.devices ?? []).subtracting([model.device])
        }
    }

    @ViewBuilder private var folder: some View {
        if let current {
            Section("Folder") {
                Text(model.folderName(current.folder) ?? "A folder this iPhone no longer uses")
            }
        } else {
            Section {
                if !model.folders.isEmpty {
                    Picker("Folder", selection: $folderID) {
                        ForEach(model.folders) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                }
                Button("Add Sync Folder…") { addingFolder = true }
            } header: {
                Text("Folder")
            } footer: {
                Text("The list syncs through a folder your devices can reach, like YANA Sync in iCloud Drive, or a folder shared with your other Apple ID.")
            }
        }
    }

    private var sendTo: some View {
        Section {
            Toggle(isOn: .constant(true)) {
                Text("This iPhone (\(model.deviceName))")
            }
            .disabled(true)
            ForEach(others, id: \.id) { card in
                Toggle(isOn: tick(card.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.name)
                        if let status = status(of: card) {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let folderID, model.unreadable.contains(folderID) {
                Text("YANA can't open this folder, so nothing syncs through it. In Settings here, remove it and add it again.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if loaded && others.isEmpty && folderID != nil {
                Text("No other devices use this folder yet. On your Mac, choose Add Sync Folder… in YANA's menu and pick this folder, and it shows up here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Send It To")
        }
    }

    private func tick(_ device: String) -> Binding<Bool> {
        Binding {
            ticked.contains(device)
        } set: { on in
            if on { ticked.insert(device) } else { ticked.remove(device) }
        }
    }

    /// When a device the list already goes to last wrote its copy of it. It tells whether that device's changes are
    /// reaching this iPhone.
    private func status(of card: DeviceCard) -> String? {
        guard let current, current.devices.contains(card.id), current.folder == folderID else { return nil }
        guard let date = heard[card.id] else { return "Hasn't picked up this list yet" }
        // Its clock may be a little ahead of this iPhone's
        return "Last heard from \(min(date, Date()).formatted(.relative(presentation: .named)))"
    }

    /// Reads the folder's devices now and every few seconds, so one that adds the folder meanwhile shows up
    private func watchDevices() async {
        loaded = false
        while !Task.isCancelled {
            guard let folderID, let folder = model.openFolder(folderID) else {
                devices = []
                loaded = true
                return
            }
            let cards = await model.sync.files.devices(in: folder)
            var heard: [String: Date] = [:]
            if let current, current.folder == folderID, let list = model.list(listID) {
                for device in current.devices where device != model.device {
                    heard[device] = await model.sync.files.heard(from: device, list: list.id, in: folder)
                }
            }
            devices = cards
            self.heard = heard
            loaded = true
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func confirm() {
        guard let folderID else { return }
        let shown = others.map(\.id)
        let picked = shown.filter { ticked.contains($0) }
        if let current {
            // Devices it already goes to that this folder doesn't list stay
            let kept = current.devices.filter { $0 != model.device && !shown.contains($0) }
            model.send(listID, to: picked + kept)
        } else {
            model.startSyncing(listID, in: folderID, to: picked)
        }
        dismiss()
    }

    private var hasProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }
}
