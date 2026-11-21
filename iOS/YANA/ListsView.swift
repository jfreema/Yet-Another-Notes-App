import SwiftUI
import UniformTypeIdentifiers

/// The lists on this iPhone. Lists your Macs send here show up on their own; + starts one here. Touch and hold a list
/// to rename it. A list whose sync folder can't be opened says so, and deleted lists wait in Recently Deleted at the
/// bottom.
struct ListsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [UUID] = []
    @State private var sheet: Sheet?
    @State private var addingFolder = false
    @State private var deleting: Note?
    @State private var problem: String?
    @State private var renaming: Note?
    @State private var newName = ""

    /// What shows over the lists, one at a time
    enum Sheet: Identifiable {
        case settings
        case deleted
        /// The lists in a sync folder, to bring here
        case folder(PhoneFolder)
        /// A device that started using a folder, to send lists to
        case offer(DeviceOffer)

        var id: String {
            switch self {
            case .settings: return "settings"
            case .deleted: return "deleted"
            case .folder(let folder): return "folder/" + folder.id
            case .offer(let offer): return "offer/" + offer.id
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                rows
            }
            .overlay {
                if model.lists.isEmpty && model.recentlyDeleted.isEmpty { empty }
            }
            .navigationTitle("Lists")
            .navigationDestination(for: UUID.self) { id in
                ListView(listID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        sheet = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        path.append(model.newList())
                    } label: {
                        Label("New List", systemImage: "plus")
                    }
                }
            }
            .refreshable {
                await model.sync.flush()
            }
            .sheet(item: $sheet) { content(of: $0) }
            .renameAlert($renaming, name: $newName, model: model)
            .onAppear {
                if let index = Self.openAtLaunch, model.lists.indices.contains(index), path.isEmpty {
                    path = [model.lists[index].id]
                }
                switch Self.showAtLaunch ?? "" {
                case "settings": sheet = .settings
                case "deleted": sheet = .deleted
                case "folder": sheet = model.folders.first.map { Sheet.folder($0) }
                default: break
                }
            }
            // A device that started using a folder is offered its lists once the lists are showing with nothing over
            // them
            .onChange(of: model.offers.first?.id, initial: true) { showOffer() }
            .onChange(of: path.isEmpty) { showOffer() }
            .onChange(of: sheet?.id) { showOffer() }
            .confirmationDialog(deleting.map { "Delete “\($0.title)”?" } ?? "", isPresented: isDeleting,
                                titleVisibility: .visible, presenting: deleting) { list in
                Button(list.sync == nil ? "Delete List" : "Remove from This iPhone", role: .destructive) {
                    model.delete(list.id)
                }
            } message: { list in
                Text(list.deleteWarning)
            }
            .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
                let added = model.addFolder(from: result)
                problem = added.problem
                // The lists already in it, to bring here
                if let folder = added.folder { show(.folder(folder)) }
            }
            .alert("Couldn't use that folder", isPresented: hasProblem) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
        }
    }

    /// The lists, and Recently Deleted under them once something's in it
    @ViewBuilder private var rows: some View {
        ForEach(model.lists, id: \.id) { list in
            NavigationLink(value: list.id) {
                ListRow(list: list, folder: model.folderName(list.sync?.folder),
                        stopped: model.syncProblem(of: list) != nil)
            }
            .contextMenu {
                Button {
                    newName = list.name ?? ""
                    renaming = list
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
            }
        }
        .onDelete { offsets in
            guard let index = offsets.first else { return }
            let list = model.lists[index]
            if list.sync == nil && list.syncable.items.isEmpty && list.name == nil {
                model.delete(list.id)
            } else {
                deleting = list
            }
        }
        .onMove { model.moveLists(from: $0, to: $1) }

        if !model.recentlyDeleted.isEmpty {
            Section {
                Button {
                    sheet = .deleted
                } label: {
                    HStack {
                        Label("Recently Deleted", systemImage: "trash")
                        Spacer()
                        Text("\(model.recentlyDeleted.count)")
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder private func content(of sheet: Sheet) -> some View {
        switch sheet {
        case .settings:
            SettingsView()
        case .deleted:
            DeletedListsView()
        case .folder(let folder):
            NavigationStack {
                FolderListsView(folder: folder, standalone: true)
            }
        case .offer(let offer):
            DeviceOfferView(offer: offer)
        }
    }

    @ViewBuilder private var empty: some View {
        if model.folders.isEmpty {
            ContentUnavailableView {
                Label("No Lists Yet", systemImage: "checklist")
            } description: {
                Text("To get your lists from YANA on your Mac, add the folder they sync through, like YANA Sync or a folder shared with you in iCloud Drive. Or tap + to start a list here.")
            } actions: {
                Button("Add Sync Folder…") { addingFolder = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView {
                Label("No Lists Yet", systemImage: "checklist")
            } description: {
                Text("Bring over the lists your other devices sync through your folder, or tap + to start a list here.")
            } actions: {
                ForEach(model.folders) { folder in
                    Button("Lists in “\(folder.name)”…") { sheet = .folder(folder) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// Shows a sheet once whatever was on screen is out of the way
    private func show(_ next: Sheet) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if sheet == nil { sheet = next }
        }
    }

    private func showOffer() {
        guard sheet == nil, path.isEmpty, !addingFolder, let offer = model.offers.first else { return }
        // Nothing left to send it by now
        guard !model.lists(notGoingTo: offer.device.id, in: offer.folder).isEmpty else {
            model.answered(offer)
            return
        }
        show(.offer(offer))
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var hasProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }
}

/// A list in the lists: its name or first task, how much of it is done, and the folder it syncs through, or that it
/// has stopped syncing
struct ListRow: View {
    let list: Note
    let folder: String?
    var stopped = false

    var body: some View {
        let tasks = list.syncable.items
        let done = tasks.filter(\.done).count
        VStack(alignment: .leading, spacing: 3) {
            Text(list.title)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(tasks.isEmpty ? "No tasks" : "\(done) of \(tasks.count) done")
                if stopped {
                    Text("·")
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .imageScale(.small)
                        .foregroundStyle(.orange)
                    Text("Not syncing")
                        .foregroundStyle(.orange)
                } else if let folder {
                    Text("·")
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .imageScale(.small)
                    Text(folder)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

extension AppModel {
    /// Adds the folder picked in Files. Gives back the folder, which may be one YANA already uses, or what went wrong.
    /// Neither if nothing was picked.
    func addFolder(from result: Result<URL, Error>) -> (folder: PhoneFolder?, problem: String?) {
        do {
            return (try addFolder(result.get()), nil)
        } catch let error as CocoaError where error.code == .userCancelled {
            return (nil, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }
}

extension Note {
    /// What deleting a list from this iPhone does, said before it's done
    var deleteWarning: String {
        sync == nil ? "It stays in Recently Deleted for 30 days."
            : "It stays on your other devices, and stops coming to this iPhone. Recently Deleted keeps a copy for 30 days."
    }
}
