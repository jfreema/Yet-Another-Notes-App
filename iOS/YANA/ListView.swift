import SwiftUI

/// A list's tasks, numbered like on the Mac. Tap a circle to check a task off, tap its text to change it, and press
/// Return in a task to start a new one below it. Touch and hold a task to drag it into a new order (or use Edit), and
/// swipe one to delete it, with Undo for a few seconds after. Rename… in the … menu names the list. A list that has
/// stopped syncing says so at the top.
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
    @State private var renaming: Note?
    @State private var newName = ""
    /// The task showing a text field to type in. The others show plain text, so touching and holding one drags it
    /// instead of selecting its text.
    @State private var editing: UUID?

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
        .onChange(of: focus) { old, new in
            // A task left empty goes away, as on the Mac
            if case .task(let id)? = old { model.removeBlank(id, in: listID) }
            switch new {
            case .task(let id)?:
                editing = id
            case .add?:
                editing = nil
            case nil:
                // Back to plain text once the keyboard has really gone, not while focus moves to another task
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if focus == nil { editing = nil }
                }
            }
        }
        .onDisappear {
            model.closed(listID)
        }
    }

    private func tasks(_ list: Note) -> some View {
        let look = Look(sticky: sticky)
        let checked = list.checkedCount
        return List {
            if let problem = model.syncProblem(of: list) {
                Label {
                    Text(problem)
                } icon: {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
                .foregroundStyle(look.doneColor)
                .listRowBackground(look.background)
            }

            ForEach(Array(list.items.enumerated()), id: \.element.id) { index, item in
                TaskRow(number: index + 1, item: item, look: look, text: text(of: item.id), focus: $focus,
                        typing: editing == item.id || focus == .task(item.id)) {
                    model.toggle(item.id, in: listID)
                } edit: {
                    go(to: .task(item.id))
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
                    // Under the tasks' text
                    .padding(.leading, Look.numberWidth + 24 + 20)
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
        .safeAreaInset(edge: .bottom) {
            // For a few seconds after tasks are deleted
            if let undo = model.undo(for: listID) {
                UndoBar(text: undo.summary) { model.undoDelete() }
                    .task(id: undo.at) {
                        // It stays for a screenshot of the sample lists
                        guard !model.isSample else { return }
                        try? await Task.sleep(for: .seconds(6))
                        if !Task.isCancelled { model.forgetUndo(at: undo.at) }
                    }
            }
        }
        .animation(.default, value: model.undo(for: listID)?.at)
        .sheet(isPresented: $showingSync) {
            SyncSettingsView(listID: listID)
        }
        .renameAlert($renaming, name: $newName, model: model)
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
            Text(list.deleteWarning)
        }
        .onAppear {
            // A new list starts with typing its first task
            if list.items.isEmpty && list.sync == nil { focus = .add }
            if ListsView.showAtLaunch == "sync" { showingSync = true }
            if ListsView.showAtLaunch == "undo", model.undo(for: listID) == nil {
                model.deleteTasks(at: [1], in: listID)
            }
        }
    }

    private func menu(_ list: Note, checked: Int) -> some View {
        Menu {
            Button {
                newName = list.name ?? ""
                renaming = list
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
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
            let next: Field?
            switch model.enter(value, in: task, of: listID) {
            case .stay: next = nil
            case .task(let id): next = .task(id)
            case .add: next = .add
            }
            if let next { go(to: next) }
        }
    }

    /// Puts the keyboard in a task or the add row, once its text field is on screen
    private func go(to next: Field) {
        if case .task(let id) = next { editing = id }
        Task { @MainActor in focus = next }
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

/// A task: its number, the circle that checks it off, and its text. The text is a text field only while you're typing
/// in it (`typing`); otherwise it's plain text that `edit` turns into one when tapped, so that touching and holding
/// the task drags it into a new order rather than selecting its text.
struct TaskRow: View {
    let number: Int
    let item: ToDo
    let look: Look
    @Binding var text: String
    var focus: FocusState<ListView.Field?>.Binding
    let typing: Bool
    let toggle: () -> Void
    let edit: () -> Void

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
            if typing {
                TextField("Task", text: $text, axis: .vertical)
                    .font(look.font)
                    .foregroundStyle(item.done ? look.doneColor : look.textColor)
                    .strikethrough(item.done, color: look.doneColor)
                    .focused(focus, equals: .task(item.id))
            } else {
                Text(item.text.isEmpty ? "Task" : item.text)
                    .font(look.font)
                    .foregroundStyle(item.done || item.text.isEmpty ? look.doneColor : look.textColor)
                    .strikethrough(item.done && !item.text.isEmpty, color: look.doneColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: edit)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Edits the task")
            }
        }
    }
}

/// Says what was just deleted, with a button that puts it back
struct UndoBar: View {
    let text: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .lineLimit(1)
            Spacer(minLength: 4)
            // The whole right end of the bar takes the tap, not just the word
            Button(action: undo) {
                Text("Undo")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
            }
        }
        .font(.subheadline)
        .padding(.leading, 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Name This List: an alert to type a list's name in, while `list` is set. `name` is what's typed, which starts as
    /// the list's name. Leaving it empty names the list after its first task again.
    func renameAlert(_ list: Binding<Note?>, name: Binding<String>, model: AppModel) -> some View {
        let showing = Binding { list.wrappedValue != nil } set: { if !$0 { list.wrappedValue = nil } }
        return alert("Name This List", isPresented: showing, presenting: list.wrappedValue) { note in
            TextField(note.contentsTitle, text: name)
                .submitLabel(.done)
            Button("Rename") { model.renameList(note.id, to: name.wrappedValue) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Leave it empty to name the list after its first task.")
        }
    }
}
