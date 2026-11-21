import SwiftUI

/// Recently Deleted: the lists deleted from this iPhone in the last 30 days. Put Back makes one a list here again, and
/// swiping one deletes it for good.
struct DeletedListsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingEmpty = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.recentlyDeleted) { entry in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.note.title)
                                    .lineLimit(1)
                                Text(detail(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("Put Back") { putBack(entry) }
                                .buttonStyle(.bordered)
                        }
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ model.recentlyDeleted[$0].id }) {
                            model.deleteForGood(id)
                        }
                        if model.recentlyDeleted.isEmpty { dismiss() }
                    }
                } footer: {
                    Text("Lists stay here for 30 days after they're deleted. One you put back is on this iPhone only, until you sync it again.")
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Delete All", role: .destructive) { confirmingEmpty = true }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete everything in Recently Deleted now?", isPresented: $confirmingEmpty,
                                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    model.emptyRecentlyDeleted()
                    dismiss()
                }
            } message: {
                Text("These lists can't be put back after this.")
            }
        }
    }

    /// “3 tasks · Deleted yesterday”
    private func detail(_ entry: DeletedList) -> String {
        let count = entry.note.items.count
        let tasks = count == 0 ? "No tasks" : count == 1 ? "1 task" : "\(count) tasks"
        // This iPhone's clock may have been set back since
        return "\(tasks) · Deleted \(min(entry.deleted, Date()).formatted(.relative(presentation: .named)))"
    }

    private func putBack(_ entry: DeletedList) {
        model.putBack(entry.id)
        if model.recentlyDeleted.isEmpty { dismiss() }
    }
}
