import SwiftUI
import UniformTypeIdentifiers

/// This iPhone's name, the sync folders it uses, and how lists look
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sticky") private var sticky = false
    @State private var name = ""
    @State private var addingFolder = false
    @State private var removing: PhoneFolder?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit { model.rename(name) }
                } header: {
                    Text("This iPhone's Name")
                } footer: {
                    Text("Your Macs show this name when you pick which devices a list goes to.")
                }

                Section {
                    ForEach(model.folders) { folder in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.name)
                            Group {
                                if model.unreadable.contains(folder.id) {
                                    Text("YANA can't open this folder. Remove it and add it again.")
                                        .foregroundStyle(.red)
                                } else {
                                    Text(listCount(in: folder))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                    }
                    .onDelete { offsets in
                        removing = offsets.first.map { model.folders[$0] }
                    }
                    Button("Add Sync Folder…") { addingFolder = true }
                } header: {
                    Text("Sync Folders")
                } footer: {
                    Text("Add the folder YANA on your Mac syncs through, like YANA Sync in iCloud Drive or a folder shared with you. Then, on the Mac, open the list's Sync Settings and tick this iPhone.")
                }

                Section {
                    Toggle("Sticky Note Look", isOn: $sticky)
                } footer: {
                    Text("Post-it yellow and Chalkboard SE, like sticky note mode on the Mac.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.versionDescription)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        model.rename(name)
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $addingFolder, allowedContentTypes: [.folder]) { result in
                problem = model.addFolder(from: result)
            }
            .alert("Couldn't use that folder", isPresented: hasProblem) {
                Button("OK") {}
            } message: {
                Text(problem ?? "")
            }
            .confirmationDialog(removing.map { "Stop using “\($0.name)”?" } ?? "", isPresented: isRemoving,
                                titleVisibility: .visible, presenting: removing) { folder in
                Button("Stop Using Folder", role: .destructive) { model.removeFolder(folder.id) }
            } message: { _ in
                Text("The lists that sync through it stay on this iPhone, but stop syncing.")
            }
        }
        .onAppear { name = model.deviceName }
        .onDisappear { model.rename(name) }
    }

    private func listCount(in folder: PhoneFolder) -> String {
        let count = model.lists.filter { $0.sync?.folder == folder.id }.count
        switch count {
        case 0: return "No lists sync through it yet"
        case 1: return "1 list syncs through it"
        default: return "\(count) lists sync through it"
        }
    }

    private var isRemoving: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    private var hasProblem: Binding<Bool> {
        Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    }
}
