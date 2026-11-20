import SwiftUI
import UniformTypeIdentifiers

/// The lists on this iPhone. Lists your Macs send here show up on their own; + starts one here.
struct ListsView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [UUID] = []
    @State private var showingSettings = false
    @State private var addingFolder = false
    @State private var deleting: Note?
    @State private var problem: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(model.lists, id: \.id) { list in
                    NavigationLink(value: list.id) {
                        ListRow(list: list, folder: model.folderName(list.sync?.folder))
                    }
                }
                .onDelete { offsets in
                    guard let index = offsets.first else { return }
                    let list = model.lists[index]
                    if list.sync == nil && list.syncable.items.isEmpty {
                        model.delete(list.id)
                    } else {
                        deleting = list
                    }
                }
                .onMove { model.moveLists(from: $0, to: $1) }
            }
            .overlay {
                if model.lists.isEmpty { empty }
            }
            .navigationTitle("Lists")
            .navigationDestination(for: UUID.self) { id in
                ListView(listID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
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
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .confirmationDialog(deleting.map { "Delete “\($0.title)”?" } ?? "", isPresented: isDeleting,
                                titleVisibility: .visible, presenting: deleting) { list in
                Button(list.sync == nil ? "Delete List" : "Remove from This iPhone", role: .destructive) {
                    model.delete(list.id)
                }
            } message: { list in
                Text(list.sync == nil ? "You can't undo this."
                     : "It stays on your other devices, and stops coming to this iPhone.")
            }
            .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
                problem = model.addFolder(from: result)
            }
            .alert("Couldn't use that folder", isPresented: hasProblem) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
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
                Text("On your Mac, open a list's Sync Settings and tick “\(model.deviceName)”. The list shows up here a few seconds later.")
            }
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var hasProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }
}

/// A list in the lists: its first task, how much of it is done, and the folder it syncs through
struct ListRow: View {
    let list: Note
    let folder: String?

    var body: some View {
        let tasks = list.syncable.items
        let done = tasks.filter(\.done).count
        VStack(alignment: .leading, spacing: 3) {
            Text(list.title)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(tasks.isEmpty ? "No tasks" : "\(done) of \(tasks.count) done")
                if let folder {
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
    /// Adds the folder picked in Files. Gives back what went wrong, if anything.
    func addFolder(from result: Result<URL, Error>) -> String? {
        do {
            try addFolder(result.get())
            return nil
        } catch let error as CocoaError where error.code == .userCancelled {
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
