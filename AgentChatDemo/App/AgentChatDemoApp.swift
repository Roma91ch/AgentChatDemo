import SwiftUI

@main
struct AgentChatDemoApp: App {
    @State private var dependencies = AppDependencies()

    var body: some Scene {
        WindowGroup {
            ChatScreen(dependencies: dependencies)
        }
    }
}
