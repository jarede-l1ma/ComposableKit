import ComposableKit
import Testing

private struct FormState: Equatable {
    var name = ""
    var age = 0
}

@Suite("Bindings")
struct BindingTests {
    @Test
    func bindingActionEqualityComparesKeyPathAndValue() {
        #expect(BindingAction<FormState>.set(\.name, "a") == .set(\.name, "a"))
        #expect(BindingAction<FormState>.set(\.name, "a") != .set(\.name, "b"))
        #expect(BindingAction<FormState>.set(\.age, 1) != .set(\.name, "1"))
    }

    @Test
    func patternMatchingByKeyPath() {
        let action = BindingAction<FormState>.set(\.age, 3)
        switch action {
        case \.name: Issue.record("should not match \\.name")
        case \.age: break
        default: Issue.record("should match \\.age")
        }
    }

    @Test
    func descriptionShowsKeyPathAndValue() {
        let text = "\(BindingAction<FormState>.set(\.age, 7))"
        #expect(text.contains("7"))
        #expect(text.contains("BindingAction.set"))
    }

    @Test
    func bindingReducerAppliesValueAndIgnoresOtherActions() {
        var state = FormFeature.State()
        _ = BindingReducer<FormFeature.State, FormFeature.Action>()
            .reduce(into: &state, action: .set(\.email, "a@b"))
        #expect(state.email == "a@b")

        _ = BindingReducer<FormFeature.State, FormFeature.Action>()
            .reduce(into: &state, action: .submit)
        #expect(state.email == "a@b")
    }

    @Test
    func macroGeneratesBindingActionAccessor() {
        #expect(FormFeature.Action.submit._bindingAction == nil)
        #expect(FormFeature.Action.binding(.set(\.email, "x"))._bindingAction == .set(\.email, "x"))
        #expect(FormFeature.Action.set(\.email, "x") == .binding(.set(\.email, "x")))
    }

    @MainActor
    @Test
    func storeBindingSetterSendsBindingAction() async {
        let store = TestStore(initialState: FormFeature.State()) { FormFeature() }
        await store.send(.set(\.acceptsTerms, true)) { $0.acceptsTerms = true }
        await store.send(.binding(.set(\.email, "x"))) { $0.email = "x" }
    }
}
