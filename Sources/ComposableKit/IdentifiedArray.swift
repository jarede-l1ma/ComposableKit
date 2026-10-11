import Foundation

// MARK: - IdentifiedArray
//
// Ordered collection with access by id, like Point-Free's `IdentifiedArray`
// (swift-identified-collections). Used with `forEach`.
//
// ```swift
// var rows: IdentifiedArrayOf<Row.State> = []
// state.rows[id: id]?.isOn = true
// ```

public typealias IdentifiedArrayOf<Element: Identifiable> = IdentifiedArray<Element.ID, Element>

public struct IdentifiedArray<ID: Hashable, Element> {
    public private(set) var ids: [ID]
    private var storage: [ID: Element]
    private let _id: (Element) -> ID

    public init(uniqueElements elements: some Sequence<Element>, id: @escaping (Element) -> ID) {
        self._id = id
        self.ids = []
        self.storage = [:]
        for element in elements {
            let elementID = id(element)
            precondition(storage[elementID] == nil, "IdentifiedArray: id duplicado \(elementID)")
            ids.append(elementID)
            storage[elementID] = element
        }
    }

    /// Elements in order.
    public var elements: [Element] {
        ids.map { storage[$0]! }
    }

    /// Access by id. Assigning `nil` removes; assigning a new value appends it.
    public subscript(id id: ID) -> Element? {
        get { storage[id] }
        set {
            if let newValue {
                precondition(_id(newValue) == id, "IdentifiedArray: the element's id does not match the subscript")
                if storage.updateValue(newValue, forKey: id) == nil { ids.append(id) }
            } else if storage.removeValue(forKey: id) != nil {
                ids.removeAll { $0 == id }
            }
        }
    }

    public func index(id: ID) -> Int? {
        ids.firstIndex(of: id)
    }

    public mutating func append(_ element: Element) {
        let id = _id(element)
        precondition(storage[id] == nil, "IdentifiedArray: id duplicado \(id)")
        ids.append(id)
        storage[id] = element
    }

    public mutating func insert(_ element: Element, at index: Int) {
        let id = _id(element)
        precondition(storage[id] == nil, "IdentifiedArray: id duplicado \(id)")
        ids.insert(id, at: index)
        storage[id] = element
    }

    @discardableResult
    public mutating func remove(id: ID) -> Element? {
        guard let element = storage.removeValue(forKey: id) else { return nil }
        ids.removeAll { $0 == id }
        return element
    }

    @discardableResult
    public mutating func remove(at index: Int) -> Element {
        let id = ids.remove(at: index)
        return storage.removeValue(forKey: id)!
    }

    public mutating func removeAll(where shouldRemove: (Element) throws -> Bool) rethrows {
        for id in ids where try shouldRemove(storage[id]!) {
            storage[id] = nil
        }
        ids.removeAll { storage[$0] == nil }
    }

    public mutating func removeAll() {
        ids.removeAll()
        storage.removeAll()
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { ids[$0] }
        var remaining = ids.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: insertAt)
        ids = remaining
    }
}

extension IdentifiedArray where Element: Identifiable, ID == Element.ID {
    public init(uniqueElements elements: some Sequence<Element>) {
        self.init(uniqueElements: elements, id: \.id)
    }

    public init() {
        self.init(uniqueElements: [Element](), id: \.id)
    }
}

extension IdentifiedArray: ExpressibleByArrayLiteral where Element: Identifiable, ID == Element.ID {
    public init(arrayLiteral elements: Element...) {
        self.init(uniqueElements: elements)
    }
}

extension IdentifiedArray: RandomAccessCollection {
    public var startIndex: Int { ids.startIndex }
    public var endIndex: Int { ids.endIndex }

    public subscript(position: Int) -> Element {
        storage[ids[position]]!
    }
}

extension IdentifiedArray: Equatable where Element: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ids == rhs.ids && lhs.storage == rhs.storage
    }
}

extension IdentifiedArray: Hashable where Element: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ids)
        for id in ids { hasher.combine(storage[id]) }
    }
}

// @unchecked Sendable: with `Sendable` `ID` and `Element`, the only unchecked field is
// `_id`, a pure, immutable accessor (e.g. `{ $0.id }`) that captures no state.
extension IdentifiedArray: @unchecked Sendable where ID: Sendable, Element: Sendable {}

extension IdentifiedArray: CustomStringConvertible {
    public var description: String {
        elements.description
    }
}
