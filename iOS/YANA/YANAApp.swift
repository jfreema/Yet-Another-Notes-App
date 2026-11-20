import SwiftUI

/// YANA for iPhone: your to-do lists from YANA on the Mac, synced through the same folder
@main
struct YANAApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ListsView()
                .environment(model)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.became(phase)
                }
        }
    }
}
