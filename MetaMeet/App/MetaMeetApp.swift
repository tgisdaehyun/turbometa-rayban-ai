import SwiftUI

@main @MainActor
struct MetaMeetApp: App {
    @StateObject private var store = MeetingStore(preview: ProcessInfo.processInfo.arguments.contains("--preview"))
    var body: some Scene { WindowGroup { MeetingView().environmentObject(store).preferredColorScheme(.dark).tint(.white) } }
}
