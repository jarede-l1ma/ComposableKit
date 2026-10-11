import Combine
import Foundation
@testable import ComposableKit
import Testing

private struct Profile: Codable, Equatable, Sendable {
    var name: String
}

/// Each test uses its own keys (`UUID`) so it can run in parallel.
private func uniqueKey(_ prefix: String = #function) -> String {
    "tests.\(prefix).\(UUID().uuidString)"
}

@Suite("Shared", .serialized)
struct SharedTests {
    @Test
    func sameKeySharesValue() {
        let key = uniqueKey()
        @Shared(.inMemory(key)) var a = 0
        @Shared(.inMemory(key)) var b = 99 // default value ignored: it already exists

        $a.withLock { $0 = 5 }

        #expect(a == 5)
        #expect(b == 5)
    }

    @Test
    func differentKeysAreIndependent() {
        @Shared(.inMemory(uniqueKey())) var a = 1
        @Shared(.inMemory(uniqueKey())) var b = 1
        $a.withLock { $0 += 1 }
        #expect(a == 2)
        #expect(b == 1)
    }

    @Test
    func withLockReturnsResult() {
        @Shared(.inMemory(uniqueKey())) var list: [Int] = []
        let count = $list.withLock { value -> Int in
            value.append(1)
            value.append(2)
            return value.count
        }
        #expect(count == 2)
        #expect(list == [1, 2])
    }

    @Test
    func equatableDynamicMemberAndDescription() {
        let key = uniqueKey()
        let a = Shared(wrappedValue: Profile(name: "a"), .inMemory(key))
        let b = Shared(wrappedValue: Profile(name: "x"), .inMemory(key))
        #expect(a == b) // same shared value
        #expect(a.name == "a")
        #expect(a.description.contains("Profile"))
    }

    /// With `defaultAppStorage` set, `.appStorage` persists (and reloads).
    @Test
    func appStoragePersistsPrimitiveAndCodableValuesWhenDefaultsAreSet() {
        let intKey = uniqueKey("int")
        let profileKey = uniqueKey("profile")
        let suite = "ComposableKit.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        withDependencies { $0.defaultAppStorage = defaults } operation: {
            do {
                @Shared(.appStorage(intKey)) var count = 0
                @Shared(.appStorage(profileKey)) var profile = Profile(name: "initial")
                $count.withLock { $0 = 42 }
                $profile.withLock { $0.name = "stored" }
            }

            #expect(defaults.integer(forKey: intKey) == 42)
            #expect(defaults.data(forKey: profileKey) != nil)

            resetSharedState(AppStorageKey<Int>.appStorage(intKey))
            resetSharedState(AppStorageKey<Profile>.appStorage(profileKey))

            @Shared(.appStorage(intKey)) var reloadedCount = 0
            @Shared(.appStorage(profileKey)) var reloadedProfile = Profile(name: "initial")
            #expect(reloadedCount == 42)
            #expect(reloadedProfile == Profile(name: "stored"))
        }
    }

    /// Without `defaultAppStorage` set, `.appStorage` in tests stays in memory
    /// only: one test does not read what another wrote.
    @Test
    func appStorageInTestsIsInMemoryOnly() {
        let key = uniqueKey()
        @Dependency(\.defaultAppStorage) var defaults
        do {
            @Shared(.appStorage(key)) var count = 0
            $count.withLock { $0 = 7 }
        }
        #expect(defaults.object(forKey: key) == nil)
        #expect(UserDefaults.standard.object(forKey: key) == nil)

        resetSharedState(AppStorageKey<Int>.appStorage(key))
        @Shared(.appStorage(key)) var reloaded = 0
        #expect(reloaded == 0)
    }

    @Test
    func fileStorageDoesNotTouchDiskInTests() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composablekit-tests-\(UUID().uuidString).json")
        @Shared(.fileStorage(url)) var profile = Profile(name: "a")
        $profile.withLock { $0.name = "b" }

        #expect(profile.name == "b")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func fileStorageWritesAndLoadsInLiveContext() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composablekit-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        withDependencies { $0 = DependencyValues(context: .live) } operation: {
            @Shared(.fileStorage(url)) var profile = Profile(name: "a")
            $profile.withLock { $0.name = "saved" }
        }
        _FileWriter.shared.flush() // the write happens on a queue, off the mutating thread
        #expect(FileManager.default.fileExists(atPath: url.path))

        resetSharedState(FileStorageKey<Profile>.fileStorage(url))
        withDependencies { $0 = DependencyValues(context: .live) } operation: {
            @Shared(.fileStorage(url)) var profile = Profile(name: "a")
            #expect(profile.name == "saved")
        }
    }

    @Test
    func keyIdsIncludeStrategy() {
        #expect(InMemoryKey<Int>.inMemory("k").id == "inMemory:k")
        #expect(AppStorageKey<Int>.appStorage("k").id == "appStorage:k")
    }

    @Test
    func resetSharedStateForOneKeyRestoresDefault() {
        let key = InMemoryKey<Int>.inMemory(uniqueKey())
        do {
            @Shared(key) var value = 1
            $value.withLock { $0 = 2 }
        }
        resetSharedState(key)
        @Shared(key) var value = 1
        #expect(value == 1)
    }

    @MainActor
    @Test
    func changeNotifiesEveryLiveStore() {
        let first = Store(initialState: SharedCounterFeature.State()) { SharedCounterFeature() }
        let second = Store(initialState: SharedCounterFeature.State()) { SharedCounterFeature() }
        let notifications = LockIsolated(0)
        let cancellable = second.objectWillChange.sink { notifications.withValue { $0 += 1 } }

        first.send(.increment)

        #expect(second.count == first.count)
        #expect(notifications.value >= 1)
        _ = cancellable
    }

    // MARK: Per-test isolation

    @Test
    func eachTestHasItsOwnScope() {
        let scope = _currentTestScope()
        #expect(scope?.contains("eachTestHasItsOwnScope") == true)
    }

    /// Two tests (scopes) with the same key: neither sees the other's value.
    @Test
    func registriesOfDifferentTestsAreIndependent() {
        let key = InMemoryKey<Int>.inMemory("tests.isolation")
        let first = _SharedRegistry.registry(forTest: "test-A.\(UUID())")
        let second = _SharedRegistry.registry(forTest: "test-B.\(UUID())")

        first.reference(for: key, default: 0).withLock { $0 = 5 }

        #expect(first.reference(for: key, default: 0).value == 5)
        #expect(second.reference(for: key, default: 0).value == 0)
    }

    /// The pair below uses the SAME key and runs in parallel (no `.serialized`
    /// in practice: each one has its own registry).
    @Test
    func isolationWriterSeesOnlyItsOwnValue() {
        @Shared(.inMemory("tests.isolation.pair")) var value = 0
        $value.withLock { $0 = 99 }
        #expect(value == 99)
    }

    @Test
    func isolationReaderStartsFromTheDefault() {
        @Shared(.inMemory("tests.isolation.pair")) var value = 0
        #expect(value == 0)
    }

    // MARK: Who gets notified

    @MainActor
    @Test
    func changeDoesNotNotifyStoresWithoutTheShared() {
        let sharedStore = Store(initialState: SharedCounterFeature.State()) { SharedCounterFeature() }
        let otherStore = Store(initialState: CounterFeature.State()) { CounterFeature() }
        let otherNotifications = LockIsolated(0)
        let cancellable = otherStore.objectWillChange.sink { otherNotifications.withValue { $0 += 1 } }

        sharedStore.send(.increment)

        #expect(otherNotifications.value == 0)
        _ = cancellable
    }

    @Test
    func containsSharedReferenceFindsNestedValues() {
        struct Row: Equatable { @Shared(.inMemory("tests.nested.row")) var count = 0 }
        enum Mode: Equatable { case empty, loaded([Row]) }
        struct State: Equatable { var title = ""; var row: Row?; var mode = Mode.empty }

        let row = Row()
        let id: Set<ObjectIdentifier> = [row.$count._sharedReferenceID]

        #expect(_containsSharedReference(State(row: row), in: id))
        #expect(_containsSharedReference(State(mode: .loaded([Row(), row])), in: id))
        #expect(!_containsSharedReference(State(), in: id))
    }

    // MARK: .fileStorage writes

    @Test
    func fileStorageWritesOffTheCallerAndKeepsTheLatestValue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composablekit-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        withDependencies { $0 = DependencyValues(context: .live) } operation: {
            @Shared(.fileStorage(url)) var count = 0
            for value in 1...500 { $count.withLock { $0 = value } }
        }
        _FileWriter.shared.flush()

        let data = try Data(contentsOf: url)
        #expect(try JSONDecoder().decode(Int.self, from: data) == 500)
    }

    /// With the queue stopped, the background/termination notification writes
    /// the pending value immediately (without it, the last change would be lost).
    @Test
    func pendingFileWritesAreFlushedWhenTheAppGoesToBackground() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("composablekit-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let notification = try #require(_FileWriter.flushNotificationNames.first)

        _FileWriter.shared._suspendQueueForTests()
        defer { _FileWriter.shared._resumeQueueForTests() }

        withDependencies { $0 = DependencyValues(context: .live) } operation: {
            @Shared(.fileStorage(url)) var count = 0
            $count.withLock { $0 = 7 }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path)) // queue stopped: not written yet

        NotificationCenter.default.post(name: notification, object: nil)

        let data = try Data(contentsOf: url)
        #expect(try JSONDecoder().decode(Int.self, from: data) == 7)
    }
}
