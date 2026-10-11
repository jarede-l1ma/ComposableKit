# ComposableKit

**A lightweight, dependency-free implementation of the API of [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) (TCA), for SwiftUI apps that still support iOS 15.**

> ComposableKit is an independent project, inspired by and API-compatible with Point-Free's TCA. It is not affiliated with or endorsed by Point-Free. See [Acknowledgments](#acknowledgments).

ComposableKit keeps Point-Free's API and names — `@Reducer`, `@ObservableState`, `Effect.run`, `@Dependency`, `@Shared`, `TestStore` — so the TCA documentation and examples apply. It runs on iOS 15, has no runtime dependencies, and works in Swift 5 and Swift 6 apps, with or without default `MainActor` isolation.

## Why it exists

Current TCA releases require **iOS 16+**. Apps that still support iOS 15 can only use older TCA releases. ComposableKit offers the same programming model on iOS 15, in a small package with **no external dependencies** (only `swift-syntax`, at build time, for the macros).

If your app targets iOS 16+, prefer the official TCA: it is more complete and actively maintained by Point-Free. Since the API is the same, moving from ComposableKit to TCA later is mostly a matter of changing the import and the adjustments listed below.

## Requirements

- iOS 15+
- Xcode 26+ (Swift 6.2 toolchain). Apps can use the Swift 5 or Swift 6 language mode.

## Installation

In Xcode: **File › Add Package Dependencies…**, enter this repository's URL and choose a version. Link the **`ComposableKit`** product to your **app target only** — the test target just uses `import ComposableKit` (linking it twice would load two copies of the library).

With a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/jarede-l1ma/ComposableKit", from: "1.0.0"),
],
targets: [
    .target(name: "MyFeature", dependencies: [
        .product(name: "ComposableKit", package: "ComposableKit"),
    ]),
]
```

The macros (`@Reducer`, `@CasePathable`, `@ObservableState`) need to be trusted once in Xcode; on the command line pass `-skipMacroValidation` to `xcodebuild`.

## Usage

```swift
import ComposableKit
import SwiftUI

@Reducer
struct CounterFeature {
    @ObservableState
    struct State: Equatable {
        var count = 0
        var fact: String?
    }

    enum Action: Equatable {
        case incrementTapped
        case factTapped
        case factResponse(String)
    }

    @Dependency(\.numberFact) var numberFact

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .incrementTapped:
                state.count += 1
                return .none
            case .factTapped:
                return .run { [count = state.count, numberFact] send in
                    await send(.factResponse(try await numberFact.fetch(count)))
                } catch: { error, send in
                    await send(.factResponse(error.localizedDescription))
                }
            case let .factResponse(fact):
                state.fact = fact
                return .none
            }
        }
    }
}

struct CounterView: View {
    @ObservedObject var store: StoreOf<CounterFeature>

    var body: some View {
        VStack {
            Text("\(store.count)")
            Button("Increment") { store.send(.incrementTapped) }
            Button("Fact") { store.send(.factTapped) }
            if let fact = store.fact { Text(fact) }
        }
    }
}

// The dependency
struct NumberFactClient: Sendable {
    var fetch: @Sendable (Int) async throws -> String
}

extension NumberFactClient: DependencyKey {
    static let liveValue = NumberFactClient { number in
        let url = URL(string: "https://api.example.com/facts/\(number)")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(decoding: data, as: UTF8.self)
    }
    static let testValue = NumberFactClient { _ in throw UnimplementedError("NumberFactClient.fetch") }
}

extension DependencyValues {
    var numberFact: NumberFactClient {
        get { self[NumberFactClient.self] }
        set { self[NumberFactClient.self] = newValue }
    }
}
```

### API

| Concept | API |
|---|---|
| Feature | `@Reducer struct XFeature` with `@ObservableState struct State`, `enum Action`, `var body: some ReducerOf<Self>` |
| Effects | `.none`, `.send`, `.run { send in } catch: { error, send in }`, `.merge`, `.concatenate`, `.cancellable(id:cancelInFlight:)`, `.cancel(id:)`, `.debounce(id:for:clock:)` |
| Dependencies | `@Dependency(\.client)`, `DependencyKey` (`liveValue` / `testValue` / `previewValue`), `withDependencies`; built in: `continuousClock`, `uuid`, `date` |
| Composition | `Scope`, `.ifLet`, `.forEach` with `IdentifiedArrayOf`, `store.scope(state:action:)` |
| Forms | `BindableAction`, `BindingReducer()`, `$store.field` |
| Shared state | `@Shared(.inMemory / .appStorage / .fileStorage)`, `$value.withLock { }` |
| Reducer modifiers | `.onChange(of:)`, `.dependency(_:_:)`, `._printChanges()` |
| Testing | exhaustive `TestStore`, `TestClock`, `LockIsolated` |

### Differences from the official TCA

| In TCA | In ComposableKit |
|---|---|
| `let store: StoreOf<X>` or `@Bindable var store` in the View | `@ObservedObject var store: StoreOf<X>` (the `Store` is an `ObservableObject`; `$store.field` works the same) |
| `WithPerceptionTracking { ... }` | Not needed |
| `@Presents` / `PresentationAction`, `StackState` | Not available: navigate through a `navigate` closure injected by whoever creates the screen (a Coordinator or router); use `.ifLet` for children inside the same screen |
| `ifCaseLet`, `@DependencyClient` | Not available: use `.ifLet` with optional state; write clients with `liveValue`/`testValue` |
| `continuousClock: any Clock<Duration>` | `any EffectClock`, with `sleep(for: Double)` in seconds |

## Testing

```swift
import ComposableKit
import Testing
@testable import MyApp

@MainActor
@Test
func factTappedShowsTheFact() async {
    let store = TestStore(initialState: CounterFeature.State(count: 3)) {
        CounterFeature()
    } withDependencies: { deps in
        deps.numberFact.fetch = { number in "\(number) is odd" }
    }

    await store.send(.factTapped)
    await store.receive(\.factResponse, "3 is odd") { state in
        state.fact = "3 is odd"
    }
}
```

**Required once per test target:** add this file. It routes `TestStore` failures to Swift Testing and gives each test its own `@Shared` values — without it, failures only show up in the console and the test passes.

```swift
// ComposableKitTestSupport.swift (in your test target)
import ComposableKit
import Foundation
import Testing

@objc(ComposableKitTestSupport)
final class ComposableKitTestSupport: NSObject, ComposableKitTestIssueReporting {
    static func reportIssue(_ message: String, fileID: String, filePath: String, line: Int, column: Int) {
        let location = SourceLocation(fileID: fileID, filePath: filePath, line: max(1, line), column: max(1, column))
        if Test.current != nil {
            Issue.record(Comment(rawValue: message), sourceLocation: location)
        } else {
            print("⚠️ [ComposableKit] \(location) — \(message)")
        }
    }

    @objc static func currentTestScope() -> String? {
        guard let test = Test.current else { return nil }
        return ([test.id.moduleName] + test.id.nameComponents).joined(separator: ".")
    }
}
```

On a slow CI, raise the `TestStore` timeout (default 1 s) with `COMPOSABLEKIT_TEST_TIMEOUT=5` (`TEST_RUNNER_COMPOSABLEKIT_TEST_TIMEOUT=5` with `xcodebuild`).

## Developing

```bash
swift build --build-tests
swift test
```

## Acknowledgments

ComposableKit would not exist without [Point-Free](https://www.pointfree.co). The architecture, its API and its names come from [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) and the libraries it builds on (swift-case-paths, swift-dependencies, swift-identified-collections, swift-sharing, swift-clocks, swift-concurrency-extras, swift-issue-reporting), all MIT-licensed. ComposableKit re-implements that API for iOS 15 without depending on them.

This project is not affiliated with or endorsed by Point-Free, Inc. See [`NOTICE`](NOTICE) for the attribution and Point-Free's license text.

## License

MIT. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
