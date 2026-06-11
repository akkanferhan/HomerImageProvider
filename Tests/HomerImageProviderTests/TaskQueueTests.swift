import Foundation
import Testing
@testable import HomerImageProvider

@Suite("TaskQueue")
struct TaskQueueTests {

    // MARK: - Concurrency cap

    @Test("execute never runs more operations than the configured cap")
    func capIsEnforced() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 2)
        let tracker = ConcurrencyTracker()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try await queue.execute {
                        await tracker.enter()
                        try await Task.sleep(nanoseconds: 5_000_000)
                        await tracker.exit()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await tracker.peak <= 2)
        #expect(await tracker.peak > 0)
    }

    @Test("a slot frees up after the operation throws")
    func slotReleasedOnThrow() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 1)
        struct OperationError: Error {}

        await #expect(throws: OperationError.self) {
            try await queue.execute { throw OperationError() }
        }

        // The deferred release runs in a detached task — wait for it.
        try await waitUntil { await queue.runningCount == 0 }
        let value = try await queue.execute { "ran" }
        #expect(value == "ran")
    }

    @Test("execute returns the operation's value")
    func returnsOperationValue() async throws {
        let queue = TaskQueue()
        let value = try await queue.execute { 21 * 2 }
        #expect(value == 42)
    }

    // MARK: - LIFO ordering

    @Test("the most recently enqueued waiter is resumed first")
    func lifoResumeOrder() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 1)
        let recorder = OrderRecorder()

        // Occupy the single slot so subsequent enqueues park as waiters.
        await queue.enqueue()

        let waiterB = Task {
            await queue.enqueue()
            await recorder.record("B")
        }
        try await waitUntil { await queue.waitingCount == 1 }

        let waiterC = Task {
            await queue.enqueue()
            await recorder.record("C")
        }
        try await waitUntil { await queue.waitingCount == 2 }

        await queue.dequeue() // resumes C (LIFO)
        try await waitUntil { await recorder.entries.count == 1 }
        await queue.dequeue() // resumes B

        _ = await waiterB.value
        _ = await waiterC.value
        await queue.dequeue() // release the final slot

        #expect(await recorder.entries == ["C", "B"])
    }

    // MARK: - Cancellation

    @Test("a task cancelled while waiting throws and releases its slot")
    func cancelledWaiterReleasesSlot() async throws {
        let queue = TaskQueue(maxConcurrentTasks: 1)

        await queue.enqueue() // saturate

        let waiter = Task {
            try await queue.execute { "never runs" }
        }
        try await waitUntil { await queue.waitingCount == 1 }

        waiter.cancel()
        await queue.dequeue() // hand the slot to the cancelled waiter

        await #expect(throws: CancellationError.self) {
            _ = try await waiter.value
        }
        // The cancelled task's deferred release must drain the queue.
        try await waitUntil { await queue.runningCount == 0 }
    }
}

// MARK: - Helpers

/// Polls `condition` until it holds, failing the test after ~2 seconds.
private func waitUntil(
    _ condition: @Sendable () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for condition")
}

private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func exit() {
        current -= 1
    }
}

private actor OrderRecorder {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}
