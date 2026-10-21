import XCTest
@testable import VoiceDictationLogic

/// U5 / v4-1: the mechanism per take. Unknown bundles never get `.ax`; the spike table (U6) fills the sets.
final class RewriteMechanismTests: XCTestCase {
    private func field(
        bundle: String?, rangeSettable: Bool = false, textSettable: Bool = false, secure: Bool = false
    ) -> FocusedField {
        FocusedField(pid: 1, bundle: bundle, role: "AXTextArea", secure: secure, caret: 0,
                     rangeSettable: rangeSettable, textSettable: textSettable)
    }

    func testSecureFieldGetsNoRewrite() {
        XCTAssertEqual(RewriteMechanism.choose(field: field(bundle: "com.apple.TextEdit", textSettable: true, secure: true)), .none)
    }

    func testNativeCocoaFieldUsesAXReplace() {
        XCTAssertEqual(RewriteMechanism.choose(field: field(bundle: "com.apple.TextEdit", textSettable: true)), .ax)
        XCTAssertEqual(RewriteMechanism.choose(field: field(bundle: "com.apple.Notes", textSettable: true)), .ax)
    }

    /// Electron editors: the selection is settable, so text goes in as real key events.
    func testElectronEditorsUseSelectThenType() {
        XCTAssertEqual(RewriteMechanism.choose(field: field(bundle: "com.microsoft.VSCode", rangeSettable: true)), .axSelectType)
        XCTAssertEqual(RewriteMechanism.choose(field: field(bundle: "com.tinyspeck.slackmacgap", rangeSettable: true)), .axSelectType)
    }

    func testUnknownAppWithSettableSelectionUsesSelectThenType() {
        XCTAssertEqual(RewriteMechanism.choose(field: field(bundle: "com.example.Editor", rangeSettable: true)), .axSelectType)
    }

    /// Unknown bundles never fall to `.ax` without spike evidence.
    func testUnknownAppWithNothingSettableUsesKeys() {
        XCTAssertEqual(RewriteMechanism.choose(field: field(bundle: "com.example.Editor")), .keys)
        XCTAssertEqual(RewriteMechanism.choose(field: field(bundle: nil)), .keys)
    }

    func testSpikeSetsAreNonEmptyAndDisjointInTheSeed() {
        XCTAssertTrue(RewriteMechanism.axWritable.contains("com.apple.TextEdit"))
        XCTAssertTrue(RewriteMechanism.axSelectable.contains("com.microsoft.VSCode"))
        XCTAssertTrue(RewriteMechanism.axWritable.isDisjoint(with: RewriteMechanism.axSelectable))
    }
}
