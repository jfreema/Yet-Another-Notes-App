import SwiftUI

/// The lists in a sync folder that your other devices have and this iPhone doesn't, each with a switch to bring it
/// here. It shows after a folder is added, and again from the folder in Settings, which is also how a list removed
/// from this iPhone comes back.
struct FolderListsView: View {
    let folder: PhoneFolder
    /// Whether it's a sheet of its own, which gets a Not Now button. In Settings, Back does that.
    var standalone = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var lists: [FolderList] = []
    @State private var ticked: Set<UUID> = []
    /// The lists shown so far, so only one that turns up starts switched on
    @State private var seen: Set<UUID> = []
    @State private var loaded = false
    @State private var cantOpen = false
    @State private var bringing = false

    /// The lists switched on, of the ones showing
    private var picked: [UUID] { lists.map(\.id).filter { ticked.contains($0) } }

    var body: some View {
        Form {
            Section {
                ForEach(lists) { list in
                    Toggle(isOn: tick(list.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.title)
                                .lineLimit(1)
                            Text(list.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                if !loaded {
                    ProgressView()
                } else if cantOpen || model.unreadable.contains(folder.id) {
                    Text("YANA can't open this folder. In Settings, remove it and add it again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if lists.isEmpty {
                    Text("There are no lists in this folder that aren't on this iPhone already. A list your other devices sync through it shows up here. If you just added the folder, iCloud Drive may need a moment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Lists in “\(folder.name)”")
            } footer: {
                if !lists.isEmpty {
                    Text("A list that's switched on comes to this iPhone and stays in sync with your other devices.")
                }
            }
        }
        .navigationTitle("Bring Lists Here")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if standalone {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Bring Here", action: bring)
                    .disabled(picked.isEmpty || bringing)
            }
        }
        .task {
            await watch()
        }
    }

    private func tick(_ list: UUID) -> Binding<Bool> {
        Binding {
            ticked.contains(list)
        } set: { on in
            if on { ticked.insert(list) } else { ticked.remove(list) }
        }
    }

    /// Reads the folder now and every few seconds, since iCloud Drive may still be downloading what's in it
    private func watch() async {
        while !Task.isCancelled {
            if let open = model.openFolder(folder.id) {
                let found = await model.sync.lists(in: open)
                ticked.formUnion(found.map(\.id).filter { !seen.contains($0) })
                seen.formUnion(found.map(\.id))
                if found != lists { lists = found }
                cantOpen = false
            } else {
                cantOpen = true
            }
            loaded = true
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func bring() {
        guard let open = model.openFolder(folder.id) else { return }
        bringing = true
        let ids = picked
        Task {
            await model.sync.join(ids, in: open)
            dismiss()
        }
    }
}

/// Shown when another device starts using a sync folder: the lists that sync through the folder and don't go to it
/// yet, to send them there too
struct DeviceOfferView: View {
    let offer: DeviceOffer
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var lists: [Note] = []
    @State private var ticked: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("“\(offer.device.name)” now uses “\(model.folderName(offer.folder) ?? "your sync folder")”. Send it the lists that sync through that folder?")
                }
                Section {
                    ForEach(lists, id: \.id) { list in
                        Toggle(list.title, isOn: tick(list.id))
                    }
                } footer: {
                    Text("A list that's switched on shows up on it and stays in sync. A list's Sync Settings changes this later.")
                }
            }
            .navigationTitle("New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        model.answered(offer, sending: lists.map(\.id).filter { ticked.contains($0) })
                        dismiss()
                    }
                    .disabled(ticked.isEmpty)
                }
            }
        }
        .onAppear {
            lists = model.lists(notGoingTo: offer.device.id, in: offer.folder)
            ticked = Set(lists.map(\.id))
        }
        // However it was closed, it isn't offered again
        .onDisappear {
            model.answered(offer)
        }
    }

    private func tick(_ list: UUID) -> Binding<Bool> {
        Binding {
            ticked.contains(list)
        } set: { on in
            if on { ticked.insert(list) } else { ticked.remove(list) }
        }
    }
}
