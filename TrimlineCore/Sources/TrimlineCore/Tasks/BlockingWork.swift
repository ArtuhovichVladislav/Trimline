import Dispatch

/// Actors whose methods block for long on file reads and decoding run on a dispatch queue of their own
/// (their `unownedExecutor`), so they don't hold up the few threads of Swift's cooperative pool.
/// `Task.isCancelled` still works inside them.
enum BlockingWork {
    static func queue(for owner: Any.Type) -> DispatchSerialQueue {
        DispatchSerialQueue(label: "Trimline.\(owner)")
    }
}
