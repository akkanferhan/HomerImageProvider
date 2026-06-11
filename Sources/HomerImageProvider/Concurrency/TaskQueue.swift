import Foundation

/// A LIFO-ordered queue that caps the number of asynchronous tasks
/// running at the same time.
///
/// LIFO ordering matters for scroll-driven image grids: when the user
/// scrolls fast, dozens of cells request loads in quick succession but
/// only the last few are actually visible. A FIFO queue would tie up
/// workers on off-screen requests while the cells the user is looking
/// at right now wait at the back of the line — the symptom is "the
/// screen full of spinners that never resolve." Popping the
/// most-recently-enqueued continuation first means a freshly
/// scrolled-into-view cell jumps the queue ahead of the no-longer-visible
/// requests still trailing behind it.
///
/// `actor` isolation serialises every access to the running counter
/// and the waiter list, so the queue is safe to share across any
/// number of concurrent producers.
public actor TaskQueue {
    private let maxConcurrentTasks: Int
    private var runningTasks = 0
    private var waitingTasks: [CheckedContinuation<Void, Never>] = []

    /// Creates a queue that will allow up to `maxConcurrentTasks`
    /// operations to run simultaneously. Defaults to `5`.
    public init(maxConcurrentTasks: Int = 5) {
        self.maxConcurrentTasks = maxConcurrentTasks
    }

    /// Number of operations currently holding a worker slot. Internal
    /// so tests can deterministically observe saturation and drain.
    var runningCount: Int { runningTasks }

    /// Number of suspended callers waiting for a slot. Internal so
    /// tests can synchronise on "waiter parked" before resuming.
    var waitingCount: Int { waitingTasks.count }

    /// Reserves a worker slot. If a slot is immediately available the
    /// call returns synchronously; otherwise it suspends until
    /// ``dequeue()`` resumes it (which can happen after an arbitrary
    /// delay if the queue is saturated).
    public func enqueue() async {
        if runningTasks < maxConcurrentTasks {
            runningTasks += 1
            return
        }

        await withCheckedContinuation { continuation in
            waitingTasks.append(continuation)
        }
    }

    /// Frees a worker slot and resumes the **most recently enqueued**
    /// waiter, if any. Off-screen image tasks remain queued and drain
    /// once the visible workload settles.
    public func dequeue() async {
        runningTasks -= 1
        if !waitingTasks.isEmpty {
            runningTasks += 1
            let continuation = waitingTasks.removeLast()
            continuation.resume()
        }
    }

    /// Reserves a slot, runs `operation`, and releases the slot when
    /// the closure returns or throws. Cancellation is checked
    /// **after** the slot is reserved so a cancelled task still
    /// gives up its slot promptly via the `defer` block.
    /// - Parameter operation: The work to perform under the
    ///   concurrency cap.
    /// - Returns: The value returned by `operation`.
    public func execute<T>(operation: @escaping @Sendable () async throws -> T) async throws -> T {
        await enqueue()
        defer {
            Task {
                await dequeue()
            }
        }

        try Task.checkCancellation()

        return try await operation()
    }
}
