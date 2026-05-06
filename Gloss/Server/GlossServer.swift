import Foundation

// CLAUDE → CODEX: this is a placeholder so GlossApp.swift compiles. Codex
// owns this file and is replacing it with a real Network.framework HTTP
// server on :7778. Public API expected by GlossApp:
//
//   @MainActor public final class GlossServer {
//       public init()
//       public func start(store: CanvasStore)
//       public func stop()
//   }
//
// CanvasStore.apply(_:) is @MainActor — bounce off the listener queue
// before calling.

@MainActor
public final class GlossServer {
    public init() {}
    public func start(store: CanvasStore) {
        NSLog("Gloss: GlossServer.start stub — Codex implementation pending")
    }
    public func stop() {}
}
