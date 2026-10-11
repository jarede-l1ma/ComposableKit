import Foundation
@testable import ComposableKit
import Testing

@Suite("LockIsolated")
struct LockIsolatedTests {
    @Test
    func readWriteAndDynamicMember() {
        let value = LockIsolated([1, 2])
        #expect(value.value == [1, 2])
        #expect(value.count == 2)
        value.withValue { $0.append(3) }
        #expect(value.value == [1, 2, 3])
        value.setValue([])
        #expect(value.value.isEmpty)
        #expect(LockIsolated(1) == LockIsolated(1))
        #expect(LockIsolated(1) != LockIsolated(2))
    }

    @Test
    func concurrentMutationsAreSafe() async {
        let counter = LockIsolated(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1_000 {
                group.addTask { counter.withValue { $0 += 1 } }
            }
        }
        #expect(counter.value == 1_000)
    }

    @Test
    func withValueReturnsResult() {
        let value = LockIsolated(5)
        let doubled = value.withValue { $0 * 2 }
        #expect(doubled == 10)
    }
}

@Suite("TestClock")
struct TestClockTests {
    @Test
    func sleepResumesOnlyAfterAdvancingEnough() async {
        let clock = TestClock()
        let finished = LockIsolated(false)
        let task = Task {
            try await clock.sleep(for: 1)
            finished.setValue(true)
        }

        await clock.advance(by: 0.5)
        #expect(!finished.value)
        await clock.advance(by: 0.5)
        _ = await task.result
        #expect(finished.value)
    }

    @Test
    func sleepsResumeInDeadlineOrder() async {
        let clock = TestClock()
        let order = LockIsolated<[Int]>([])
        let slow = Task { try await clock.sleep(for: 2); order.withValue { $0.append(2) } }
        let fast = Task { try await clock.sleep(for: 1); order.withValue { $0.append(1) } }

        await clock.run()
        _ = await (slow.result, fast.result)
        #expect(order.value == [1, 2])
    }

    @Test
    func zeroSleepResumesImmediately() async throws {
        try await TestClock().sleep(for: 0)
    }

    @Test
    func cancellingSleepThrows() async {
        let clock = TestClock()
        let task = Task { try await clock.sleep(for: 10) }
        await Task.megaYield()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func sleepInCancelledTaskThrows() async {
        let clock = TestClock()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: 1)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func runWithoutPendingSleepsIsNoOp() async {
        await TestClock().run()
    }
}

@Suite("Internals")
struct InternalTests {
    @Test
    func isEqualForEquatableAndNonEquatable() {
        struct NotEquatable {}
        #expect(_isEqual(1, 1) == true)
        #expect(_isEqual(1, 2) == false)
        #expect(_isEqual(1, "1") == false)
        #expect(_isEqual(NotEquatable(), NotEquatable()) == nil)
    }

    @Test
    func taskBagTracksAndCancels() async {
        let bag = _TaskBag()
        let first = UUID(), second = UUID()
        let t1 = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 10_000_000_000) }
        let t2 = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 10_000_000_000) }
        bag.insert(first, t1)
        bag.insert(second, t2)
        #expect(bag.count == 2)

        bag.cancel([first])
        #expect(t1.isCancelled)
        #expect(!t2.isCancelled)
        #expect(bag.count == 1)

        bag.remove(second)
        #expect(bag.count == 0)
        bag.insert(second, t2)
        bag.cancelAll()
        #expect(t2.isCancelled)
        #expect(bag.count == 0)
    }

    @Test
    func combineTasks() async {
        #expect(_combine([]) == nil)
        let single = Task<Void, Never> {}
        #expect(_combine([single]) == single)

        let done = LockIsolated(0)
        let a = Task { done.withValue { $0 += 1 } }
        let b = Task { done.withValue { $0 += 1 } }
        await _combine([a, b])?.value
        #expect(done.value == 2)

        let slow = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 10_000_000_000) }
        let combined = _combine([slow, Task<Void, Never> {}])
        combined?.cancel()
        await combined?.value
        #expect(slow.isCancelled)
    }

    @Test
    func lineDiffMarksRemovedAndAddedLines() {
        let diff = lineDiff(expected: "a\nb\nc", actual: "a\nx\nc")
        #expect(diff == "  a\n− b\n+ x\n  c")
        #expect(lineDiff(expected: "a", actual: "a") == "  a")
        #expect(lineDiff(expected: "", actual: "z").contains("+ z"))
    }

    @Test
    func debugTextDumpsValue() {
        #expect(debugText(Log(entries: ["x"])).contains("\"x\""))
    }
}

@Suite("IssueReporting")
struct IssueReportingTests {
    @Test
    func reportIssueBecomesTestFailureThroughComposableKitTestSupport() {
        withKnownIssue {
            reportIssue("test message")
        } matching: { issue($0, contains: "test message") }
    }

    @Test
    func testReporterFunctionIsFound() {
        #expect(_testIssueReporter() != nil)
    }

    @Test
    func customReporterReceivesMessageAndLocation() {
        let captured = LockIsolated<(String, UInt)?>(nil)
        let reporter = IssueReporter { message, _, _, line, _ in
            captured.setValue((message, line))
        }
        reporter.report("x", #fileID, #filePath, 7, 1)
        #expect(captured.value?.0 == "x")
        #expect(captured.value?.1 == 7)
    }
}
