import SwiftUI

/// A list's tasks, numbered like on the Mac. Tap a circle to check a task off, tap its text to change it, and press
/// Return in a task to start a new one below it. Swipe a task to delete it; Edit drags them into a new order.
struct ListView: View {
    let listID: UUID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("sticky") private var sticky = false
    @FocusState private var focus: Field?
    @State private var newTask = ""
    @State private var showingSync = false
    @State private var confirmingClear = false
    @State private var confirmingDelete = false

    enum Field: Hashable {
        case task(UUID)
        case add
    }

    var body: some View {
        Group {
            if let list = model.list(listID) {
                tasks(list)
            } else {
                ContentUnavailableView("List Removed", systemImage: "checklist",
                                       description: Text("This list no longer comes to this iPhone."))
            }
        }
        .onChange(of: focus) { old, _ in
            // A task left empty goes away, as on the Mac
            if case .task(let id)? = old { model.removeBlank(id, in: listID) }
        }
        .onDisappear {
            model.closed(listID)
        }
    }

    private func tasks(_ list: Note) -> some View {
        let look = Look(sticky: sticky)
        let checked = list.checkedCount
        return List {
            ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
                TaskRow(number: index + 1, item: item, look: look, text: text(of: item.id), focus: $focus) {
                    model.toggle(item.id, in: listID)
                }
                .listRowBackground(look.background)
            }
            .onDelete { model.deleteTasks(at: $0, in: listID) }
            .onMove { model.moveTasks(from: $0, to: $1, in: listID) }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Color.clear.frame(width: Look.numberWidth, height: 1)
                Image(systemName: "plus")
                    .font(.title3)
                    .foregroundStyle(look.numberColor)
                    .frame(width: 24)
                TextField("Add a task", text: $newTask)
                    .font(look.font)
                    .foregroundStyle(look.textColor)
                    .focused($focus, equals: .add)
                    .submitLabel(.next)
                    .onSubmit(addTask)
            }
            .listRowBackground(look.background)

            if checked > 0 {
                Button("Clear Checked (\(checked))") { confirmingClear = true }
                    .font(.footnote)
                    .foregroundStyle(look.doneColor)
                    .listRowBackground(look.background)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(look.background == nil ? .automatic : .hidden)
        .background(look.background ?? .clear)
        .preferredColorScheme(sticky ? .light : nil)
        .navigationTitle(list.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                menu(list, checked: checked)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
        .refreshable {
            await model.sync.flush()
        }
        .sheet(isPresented: $showingSync) {
            SyncSettingsView(listID: listID)
        }
        .confirmationDialog("Clear the \(checked) checked tasks?", isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("Clear Checked", role: .destructive) { model.clearChecked(in: listID) }
        }
        .confirmationDialog(list.sync == nil ? "Delete this list?" : "Remove this list from this iPhone?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(list.sync == nil ? "Delete List" : "Remove from This iPhone", role: .destructive) {
                model.delete(listID)
                dismiss()
            }
        } message: {
            Text(list.sync == nil ? "You can't undo this."
                 : "It stays on your other devices, and stops coming to this iPhone.")
        }
        .onAppear {
            // A new list starts with typing its first task
            if list.items.isEmpty && list.sync == nil { focus = .add }
        }
    }

    private func menu(_ list: Note, checked: Int) -> some View {
        Menu {
            Button {
                showingSync = true
            } label: {
                Label(list.sync == nil ? "Sync This List…" : "Sync Settings…",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            if checked > 0 {
                Button {
                    confirmingClear = true
                } label: {
                    Label("Clear Checked (\(checked))", systemImage: "checkmark.circle")
                }
            }
            ShareLink(item: list.syncable.plainText) {
                Label("Share as Text", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Label(list.sync == nil ? "Delete List" : "Remove from This iPhone", systemImage: "trash")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    /// A task's text, as typed. Return comes in as a new line, which `Note.enter` turns into a new task.
    private func text(of task: UUID) -> Binding<String> {
        Binding {
            model.list(listID)?.items.first { $0.id == task }?.text ?? ""
        } set: { value in
            switch model.enter(value, in: task, of: listID) {
            case .stay: break
            case .task(let next): focus = .task(next)
            case .add: focus = .add
            }
        }
    }

    private func addTask() {
        let typed = newTask
        newTask = ""
        guard model.add(typed, to: listID) else {
            // Return with nothing typed is done adding
            focus = nil
            return
        }
        // Keeps the keyboard up for the next one
        Task { @MainActor in focus = .add }
    }
}

/// A task: its number, the circle that checks it off, and its text
struct TaskRow: View {
    let number: Int
    let item: ToDo
    let look: Look
    @Binding var text: String
    var focus: FocusState<ListView.Field?>.Binding
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(look.numberFont)
                .foregroundStyle(look.numberColor)
                .frame(width: Look.numberWidth, alignment: .trailing)
            Button(action: toggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.done ? look.checkColor : look.numberColor)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Checked" : "Not checked")
            TextField("Task", text: $text, axis: .vertical)
                .font(look.font)
                .foregroundStyle(item.done ? look.doneColor : look.textColor)
                .strikethrough(item.done, color: look.doneColor)
                .focused(focus, equals: .task(item.id))
        }
    }
}
