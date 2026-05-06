import SwiftUI

@main
struct GlossApp: App {
    @State private var store = CanvasStore(width: 1024, height: 1024)
    @State private var server = GlossServer()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 720, minHeight: 760)
                .onAppear {
                    server.start(store: store)
                }
        }
        .defaultSize(width: 1100, height: 1180)
        .windowStyle(.hiddenTitleBar)
    }
}
