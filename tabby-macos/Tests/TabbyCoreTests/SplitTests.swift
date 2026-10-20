import XCTest
@testable import TabbyCore

final class SplitTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    func assertInvariants(_ l: SplitLayout, file: StaticString = #filePath, line: UInt = #line) {
        func check(_ c: SplitContainer) {
            XCTAssertEqual(c.children.count, c.ratios.count, file: file, line: line)
            if !c.ratios.isEmpty {
                XCTAssertEqual(c.ratios.reduce(0, +), 1, accuracy: 1e-9, file: file, line: line)
            }
            for child in c.children {
                if case .container(let inner) = child {
                    XCTAssertGreaterThan(inner.children.count, 1, "no single-child containers", file: file, line: line)
                    XCTAssertNotEqual(inner.orientation, c.orientation, "same-orientation containers are flattened", file: file, line: line)
                    check(inner)
                }
            }
        }
        check(l.root)
        XCTAssertEqual(Set(l.panes).count, l.panes.count, "no duplicate panes", file: file, line: line)
    }

    func testSplitRightThenBottom() {
        var l = SplitLayout(single: a)
        l.insert(b, relativeTo: a, side: .right)
        XCTAssertEqual(l.root.orientation, .horizontal)
        XCTAssertEqual(l.panes, [a, b])
        XCTAssertEqual(l.root.ratios, [0.5, 0.5])
        l.insert(c, relativeTo: b, side: .bottom)
        XCTAssertEqual(l.panes, [a, b, c])
        guard case .container(let inner) = l.root.children[1] else { return XCTFail() }
        XCTAssertEqual(inner.orientation, .vertical)
        assertInvariants(l)
    }

    func testSplitBottomOfSingleChangesRootOrientation() {
        var l = SplitLayout(single: a)
        l.insert(b, relativeTo: a, side: .bottom)
        XCTAssertEqual(l.root.orientation, .vertical)
        XCTAssertEqual(l.panes, [a, b])
        l.insert(c, relativeTo: a, side: .top)
        XCTAssertEqual(l.panes, [c, a, b])
        XCTAssertEqual(l.root.ratios.count, 3)
        assertInvariants(l)
    }

    func testRemoveCollapses() {
        var l = SplitLayout(single: a)
        l.insert(b, relativeTo: a, side: .right)
        l.insert(c, relativeTo: b, side: .bottom)
        let focus = l.remove(c)
        XCTAssertEqual(focus, b)
        XCTAssertEqual(l.panes, [a, b])
        XCTAssertEqual(l.root.orientation, .horizontal)
        assertInvariants(l)
        l.remove(a)
        l.remove(b)
        XCTAssertTrue(l.isEmpty)
    }

    func testLayoutAndNavigation() {
        var l = SplitLayout(single: a)
        l.insert(b, relativeTo: a, side: .right)
        l.insert(c, relativeTo: b, side: .bottom)
        let frames = l.layout(in: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(frames[b], CGRect(x: 100, y: 0, width: 100, height: 50))
        XCTAssertEqual(frames[c], CGRect(x: 100, y: 50, width: 100, height: 50))
        XCTAssertEqual(l.neighbour(of: a, direction: .right), b)
        XCTAssertEqual(l.neighbour(of: c, direction: .top), b)
        XCTAssertEqual(l.neighbour(of: c, direction: .left), a)
        XCTAssertEqual(l.neighbour(of: a, direction: .left), a, "no neighbour returns itself")
        XCTAssertEqual(l.pane(after: c, delta: 1), a)
        XCTAssertEqual(l.pane(after: a, delta: -1), c)
        let dividers = l.dividers(in: CGRect(x: 0, y: 0, width: 200, height: 100), spacing: 0, thickness: 6)
        XCTAssertEqual(dividers.count, 2)
    }

    func testResizeAndDivider() {
        var l = SplitLayout(single: a)
        l.insert(b, relativeTo: a, side: .right)
        XCTAssertTrue(l.resize(a, orientation: .horizontal, by: 0.1))
        XCTAssertEqual(l.root.ratios[0], 0.6, accuracy: 1e-9)
        XCTAssertEqual(l.root.ratios[1], 0.4, accuracy: 1e-9)
        XCTAssertFalse(l.resize(a, orientation: .vertical, by: 0.1), "no vertical split to resize")
        l.moveDivider(containerPath: [], index: 1, to: 0.25)
        XCTAssertEqual(l.root.ratios[0], 0.25, accuracy: 1e-9)
        l.moveDivider(containerPath: [], index: 1, to: 0.0)
        XCTAssertEqual(l.root.ratios[0], 0.05, accuracy: 1e-9, "clamped to minimum")
        assertInvariants(l)
    }

    func testNormalizeFlattensSameOrientation() {
        let inner = SplitContainer(orientation: .horizontal, children: [.leaf(b), .leaf(c)], ratios: [0.5, 0.5])
        let l = SplitLayout(root: SplitContainer(orientation: .horizontal, children: [.leaf(a), .container(inner)], ratios: [0.5, 0.5]))
        XCTAssertEqual(l.panes, [a, b, c])
        XCTAssertEqual(l.root.ratios, [0.5, 0.25, 0.25])
        assertInvariants(l)
    }

    func testEdgeInsert() {
        var l = SplitLayout(single: a)
        l.insert(b, relativeTo: a, side: .right)
        l.insert(c, relativeTo: nil, side: .bottom)
        XCTAssertEqual(l.root.orientation, .vertical)
        XCTAssertEqual(l.panes, [a, b, c])
        assertInvariants(l)
    }

    func testReplaceAndEqualize() {
        var l = SplitLayout(single: a)
        l.insert(b, relativeTo: a, side: .right)
        l.resize(a, orientation: .horizontal, by: 0.2)
        l.replace(b, with: d)
        XCTAssertEqual(l.panes, [a, d])
        l.equalize()
        XCTAssertEqual(l.root.ratios, [0.5, 0.5])
    }
}
