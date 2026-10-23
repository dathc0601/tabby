#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import TabbyCore
@testable import TabbyApp

/// Settings pages fit the window instead of widening the tab. Found in the M6 walk: in a
/// 706 pt window the Color scheme page asked for more width than it had, so the settings
/// view grew and pushed the sidebar off the left edge.
@MainActor
final class SettingsLayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func width(of section: SettingsSection, proposed: CGFloat) -> CGFloat {
        let navigation = SettingsNavigation()
        navigation.section = section
        let host = NSHostingController(rootView: SettingsRootView(navigation: navigation))
        return host.sizeThatFits(in: CGSize(width: proposed, height: 700)).width
    }

    func testEveryPageFitsANarrowWindow() {
        for section in SettingsSection.allCases {
            XCTAssertLessThanOrEqual(width(of: section, proposed: 640), 640.5, "\(section.rawValue) is wider than the window")
        }
    }

    /// The page itself fits (rather than being cut off): 640 pt minus the 221 pt sidebar.
    func testTheColorSchemePageFitsBesideTheSidebar() {
        let host = NSHostingController(rootView: ColorSchemeSettingsView())
        XCTAssertLessThanOrEqual(host.sizeThatFits(in: CGSize(width: 419, height: 700)).width, 419.5)
    }
}
#endif
