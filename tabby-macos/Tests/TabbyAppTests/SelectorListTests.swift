#if canImport(AppKit)
import XCTest
@testable import TabbyApp

/// The selector's rows (designs C4, C5, C8): matches stay in their groups, each group under
/// its header, with or without a query; free-input rows can lead the list.
@MainActor
final class SelectorListTests: XCTestCase {
    func item(_ id: String, _ group: String = "", _ title: String? = nil) -> SelectorItem {
        SelectorItem(id: id, title: title ?? id, group: group) {}
    }

    func testGroupsKeepTheOrderOfTheirFirstMatch() {
        let ranked = [item("a1", "A"), item("b1", "B"), item("a2", "A"), item("c1", "C"), item("b2", "B")]
        XCTAssertEqual(SelectorList.grouped(ranked).map(\.id), ["a1", "a2", "b1", "b2", "c1"],
                       "the best match stays first; its group follows it")
    }

    func testHeadersShowWheneverTheGroupChanges() {
        let rows = [item("a1", "Saved profiles"), item("a2", "Saved profiles"), item("t"), item("p1", "Ports")]
        XCTAssertEqual(rows.indices.map { SelectorList.header(at: $0, in: rows) }, ["Saved profiles", nil, nil, "Ports"])
    }

    func testRowsWithAQueryAreGroupedAndFreeInputCanLead() {
        let items = [item("x", "Ports", "cu.usbserial"), item("y", "Built in", "cu.debug-console")]
        let typed = { (q: String) in q.isEmpty ? [] : [self.item("use", "", "Use \(q)")] }
        XCTAssertEqual(SelectorList.rows(items: items, query: "", dynamicItems: typed, dynamicFirst: true).map(\.id), ["x", "y"])
        XCTAssertEqual(SelectorList.rows(items: items, query: "debug", dynamicItems: typed, dynamicFirst: true).map(\.id), ["use", "y"])
        XCTAssertEqual(SelectorList.rows(items: items, query: "debug", dynamicItems: typed, dynamicFirst: false).map(\.id), ["y", "use"])
    }

    func testTheDefaultFooterHintNamesTheProfileAndCommandSelectors() {
        TestApp.boot()
        XCTAssertEqual(SelectorConfig(placeholder: "p", items: []).trailingHint, SelectorPanel.profilesAndCommandsHint)
        XCTAssertNotNil(SelectorPanel.profilesAndCommandsHint)
    }
}
#endif
