import SwiftUI

@main @MainActor
struct MetaMeetApp: App {
    @StateObject private var store = MeetingStore(preview: ProcessInfo.processInfo.arguments.contains("--preview"))
    @StateObject private var meta = MetaConnection(preview: ProcessInfo.processInfo.arguments.contains("--preview"))
    var body: some Scene {
        WindowGroup {
            MeetingView().environmentObject(store).environmentObject(meta).preferredColorScheme(.dark).tint(.white)
                .onOpenURL { url in Task { await meta.handle(url) } }
        }
    }
}
