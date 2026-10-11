import ComposableKit
import Testing

@CasePathable
enum Shapes: Equatable {
    case empty
    case circle(radius: Int)
    case unlabeled(String)
    case rect(width: Int, height: Int)
    case mixed(Int, label: String)
}

@CasePathable
public enum PublicAction: Equatable {
    case tap
}

@Suite("CasePaths")
struct CasePathsTests {
    @Test
    func voidCase() {
        #expect(Shapes.empty.is(\.empty))
        #expect(Shapes.empty[case: \.empty] != nil)
        #expect(Shapes.allCasePaths.empty.embed(()) == .empty)
        #expect(Shapes.circle(radius: 1)[case: \.empty] == nil)
    }

    @Test
    func labeledSingleValue() {
        let shape = Shapes.circle(radius: 3)
        #expect(shape[case: \.circle] == 3)
        #expect(Shapes.allCasePaths.circle.embed(5) == .circle(radius: 5))
    }

    @Test
    func unlabeledSingleValue() {
        #expect(Shapes.unlabeled("x")[case: \.unlabeled] == "x")
        #expect(Shapes.allCasePaths.unlabeled.embed("y") == .unlabeled("y"))
    }

    @Test
    func multipleValuesBecomeTuple() throws {
        let rect = try #require(Shapes.rect(width: 2, height: 3)[case: \.rect])
        #expect(rect.0 == 2)
        #expect(rect.1 == 3)
        #expect(Shapes.allCasePaths.rect.embed((4, 5)) == .rect(width: 4, height: 5))

        let mixed = try #require(Shapes.mixed(1, label: "a")[case: \.mixed])
        #expect(mixed.0 == 1)
        #expect(mixed.1 == "a")
        #expect(Shapes.allCasePaths.mixed.embed((2, "b")) == .mixed(2, label: "b"))
    }

    @Test
    func otherCaseExtractsNil() {
        #expect(Shapes.empty[case: \.circle] == nil)
        #expect(!Shapes.empty.is(\.rect))
    }

    @Test
    func publicEnumGetsPublicCasePaths() {
        #expect(PublicAction.tap.is(\.tap))
    }

    @Test
    func anyCasePathManual() {
        let path = AnyCasePath<Int?, Int>(embed: { $0 }, extract: { $0 })
        #expect(path.embed(1) == 1)
        #expect(path.extract(from: nil) == nil)
    }

    @Test
    func identifiedActionCasePath() throws {
        let action = IdentifiedAction<Int, String>.element(id: 1, action: "x")
        let element = try #require(action[case: \.element])
        #expect(element.id == 1)
        #expect(element.action == "x")
        #expect(IdentifiedAction<Int, String>.allCasePaths.element.embed((2, "y")) == .element(id: 2, action: "y"))
    }
}
