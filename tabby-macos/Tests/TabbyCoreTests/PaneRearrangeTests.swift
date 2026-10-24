import XCTest
@testable import TabbyCore

/// Phase 6: Tabby's `rearrange-panes` (a modifier-only chord held down), moving a pane within
/// its split (`SplitTabComponent.add` after a drop), and the pane label flag in recovery tokens.
final class PaneRearrangeTests: XCTestCase {
    func testAModifierOnlyBindingMatchesWhileItsModifiersAreHeld() throws {
        let matcher = HotkeyMatcher(bindings: [
            "rearrange-panes": [try XCTUnwrap(HotkeyBinding("Ctrl-Shift"))],
            "new-tab": [try XCTUnwrap(HotkeyBinding("⌘-T"))],
            "other": [try XCTUnwrap(HotkeyBinding("⌘-⌥"))],
        ])
        let ids: Set<String> = ["rearrange-panes"]
        XCTAssertEqual(matcher.modifierOnlyMatch([.control, .shift], among: ids), "rearrange-panes")
        XCTAssertNil(matcher.modifierOnlyMatch([.control], among: ids))
        XCTAssertNil(matcher.modifierOnlyMatch([.control, .shift, .command], among: ids), "exactly these modifiers")
        XCTAssertNil(matcher.modifierOnlyMatch([], among: ids))
        XCTAssertNil(matcher.modifierOnlyMatch([.command, .option], among: ids), "only ids that use modifier-only bindings")
    }

    func layout(_ ids: [UUID]) -> SplitLayout {
        var l = SplitLayout(single: ids[0])
        for id in ids.dropFirst() { l.insert(id, relativeTo: l.panes.last, side: .right) }
        return l
    }

    func testMovingAPaneInsertsItWhereItWasDropped() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var l = layout([a, b, c])
        XCTAssertTrue(l.move(a, relativeTo: c, side: .right))
        XCTAssertEqual(l.panes, [b, c, a])
        XCTAssertEqual(l.root.ratios.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertTrue(l.move(a, relativeTo: b, side: .bottom))
        XCTAssertEqual(l.panes, [b, a, c], "a under b, inside a new column")
        XCTAssertTrue(l.move(c, relativeTo: nil, side: .top))
        XCTAssertEqual(l.root.orientation, .vertical, "the outer top edge spans the whole layout")
        XCTAssertEqual(l.panes.first, c)
    }

    func testMovesThatMakeNoSenseAreRefused() {
        let (a, b) = (UUID(), UUID())
        var single = SplitLayout(single: a)
        XCTAssertFalse(single.move(a, relativeTo: nil, side: .left), "the only pane")
        var l = layout([a, b])
        XCTAssertFalse(l.move(a, relativeTo: a, side: .left), "next to itself")
        XCTAssertFalse(l.move(UUID(), relativeTo: a, side: .left), "not in this layout")
        XCTAssertEqual(l.panes, [a, b])
    }

    func testThePaneLabelFlagIsKept() throws {
        var p = PaneRecovery(type: "app:local-tab", profile: Profile(id: "local:x", type: "local", name: "x", options: [:]),
                             customTitle: "logs")
        XCTAssertTrue(p.customTitleVisible, "Tabby shows a custom title unless hidden")
        p.customTitleVisible = false
        let value = RecoveryToken.pane(p).configValue
        XCTAssertEqual(value["tabCustomTitleVisible"], .bool(false))
        guard case .pane(let back)? = RecoveryToken(value) else { return XCTFail() }
        XCTAssertFalse(back.customTitleVisible)
        guard case .object(var fields) = value else { return XCTFail() }
        fields["tabCustomTitleVisible"] = nil
        guard case .pane(let old)? = RecoveryToken(.object(fields)) else { return XCTFail() }
        XCTAssertTrue(old.customTitleVisible, "older tokens: visible (Tabby's `?? true`)")
    }
}
