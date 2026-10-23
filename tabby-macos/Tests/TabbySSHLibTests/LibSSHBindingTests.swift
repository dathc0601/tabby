#if os(macOS)
import XCTest
@testable import TabbySSHLib

/// libssh is linked and initialised.
final class LibSSHBindingTests: XCTestCase {
    func testLibraryVersion() {
        XCTAssertTrue(LibSSH.version.hasPrefix("0.12"), LibSSH.version)
    }
}
#endif
