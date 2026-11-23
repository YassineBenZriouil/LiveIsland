import Testing
@testable import LiveIslandCore

@Suite("Island display")
struct DisplayChoiceTests {
    let builtIn = DisplayChoice.Display(id: "BUILT-IN", hasNotch: true, isPrimary: false)
    let studio = DisplayChoice.Display(id: "STUDIO", hasNotch: false, isPrimary: true)
    let side = DisplayChoice.Display(id: "SIDE", hasNotch: false, isPrimary: false)

    @Test func automaticPrefersTheNotch() {
        #expect(DisplayChoice.automatic.pick(from: [studio, builtIn, side]) == 1)
    }

    @Test func automaticWithoutANotchUsesTheMenuBarDisplay() {
        // A closed MacBook on an external display, or a Mac without a notch.
        #expect(DisplayChoice.automatic.pick(from: [side, studio]) == 1)
    }

    @Test func goesWhereThePersonPicked() {
        #expect(DisplayChoice.display("SIDE").pick(from: [studio, builtIn, side]) == 2)
    }

    @Test func aPickedDisplayThatIsUnpluggedFallsBackToAutomatic() {
        #expect(DisplayChoice.display("SIDE").pick(from: [studio, builtIn]) == 1)
    }

    @Test func noDisplaysNoPick() {
        #expect(DisplayChoice.automatic.pick(from: []) == nil)
        #expect(DisplayChoice.display("SIDE").pick(from: []) == nil)
    }

    @Test func savesAsText() {
        #expect(DisplayChoice(saved: nil) == .automatic)
        #expect(DisplayChoice(saved: "") == .automatic)
        #expect(DisplayChoice(saved: "SIDE") == .display("SIDE"))
        #expect(DisplayChoice(saved: DisplayChoice.display("SIDE").saved) == .display("SIDE"))
        #expect(DisplayChoice.automatic.saved == "")
    }
}
