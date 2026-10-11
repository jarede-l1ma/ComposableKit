import Foundation
import ComposableKit
import Testing

private struct Item: Identifiable, Equatable, Hashable {
    let id: Int
    var name: String
}

@Suite("IdentifiedArray")
struct IdentifiedArrayTests {
    private let a = Item(id: 1, name: "a")
    private let b = Item(id: 2, name: "b")
    private let c = Item(id: 3, name: "c")

    @Test
    func initKeepsOrderAndIds() {
        let array: IdentifiedArrayOf<Item> = [a, b, c]
        #expect(array.ids == [1, 2, 3])
        #expect(array.elements == [a, b, c])
        #expect(array.count == 3)
        #expect(array[1] == b)
        #expect(Array(array) == [a, b, c])
        #expect(IdentifiedArrayOf<Item>().isEmpty)
    }

    @Test
    func initWithCustomId() {
        let array = IdentifiedArray(uniqueElements: ["x", "yy"], id: \.count)
        #expect(array.ids == [1, 2])
        #expect(array[id: 2] == "yy")
    }

    @Test
    func subscriptByIdReadsUpdatesInsertsAndRemoves() {
        var array: IdentifiedArrayOf<Item> = [a, b]

        #expect(array[id: 2] == b)
        #expect(array[id: 9] == nil)

        array[id: 2]?.name = "B"
        #expect(array[id: 2]?.name == "B")
        #expect(array.ids == [1, 2])

        array[id: 3] = c
        #expect(array.ids == [1, 2, 3])

        array[id: 1] = nil
        #expect(array.ids == [2, 3])

        array[id: 99] = nil // removing a missing element does nothing
        #expect(array.ids == [2, 3])
    }

    @Test
    func appendInsertIndexAndRemove() {
        var array: IdentifiedArrayOf<Item> = []
        array.append(a)
        array.append(c)
        array.insert(b, at: 1)
        #expect(array.ids == [1, 2, 3])
        #expect(array.index(id: 3) == 2)
        #expect(array.index(id: 9) == nil)

        #expect(array.remove(id: 2) == b)
        #expect(array.remove(id: 2) == nil)
        #expect(array.remove(at: 0) == a)
        #expect(array.ids == [3])
    }

    @Test
    func removeAllWhereAndRemoveAll() {
        var array: IdentifiedArrayOf<Item> = [a, b, c]
        array.removeAll { $0.id.isMultiple(of: 2) }
        #expect(array.ids == [1, 3])
        array.removeAll()
        #expect(array.isEmpty)
    }

    @Test(arguments: [
        (IndexSet([0]), 3, [2, 3, 1]),
        (IndexSet([2]), 0, [3, 1, 2]),
        (IndexSet([0, 1]), 3, [3, 1, 2]),
        (IndexSet([1]), 1, [1, 2, 3]),
    ])
    func moveReordersIds(source: IndexSet, destination: Int, expected: [Int]) {
        var array: IdentifiedArrayOf<Item> = [a, b, c]
        array.move(fromOffsets: source, toOffset: destination)
        #expect(array.ids == expected)
    }

    @Test
    func equatableHashableAndDescription() {
        let x: IdentifiedArrayOf<Item> = [a, b]
        let y: IdentifiedArrayOf<Item> = [a, b]
        let z: IdentifiedArrayOf<Item> = [b, a]
        #expect(x == y)
        #expect(x != z)
        #expect(x.hashValue == y.hashValue)
        #expect(Set([x, y]).count == 1)
        #expect(x.description == [a, b].description)
    }
}
