#if canImport(AppKit)
import XCTest
@testable import TabbyApp

/// The recovery key card says what fits the moment it is shown for.
@MainActor
final class AccountSheetTextTests: XCTestCase {
    func testSignUpIsTheSecondStep() {
        let t = RecoveryKeyTexts(purpose: .signUp, profiles: 1)
        XCTAssertEqual(t.step, "Step 2 of 2")
        XCTAssertEqual(t.footer, "1 profile on this Mac will upload next")
        XCTAssertEqual(t.confirm, "Start syncing")
        XCTAssertTrue(t.needsSavedConfirmation)
        XCTAssertEqual(RecoveryKeyTexts(purpose: .signUp, profiles: 3).footer, "3 profiles on this Mac will upload next")
    }

    /// Found in the M7 walk: Regenerate… showed "Step 2 of 2", "1 profile on this Mac will
    /// upload next" and "Start syncing", and View… only wrote the key below the fold.
    func testRegeneratedAndViewedKeysAreNotASignUp() {
        let regenerated = RecoveryKeyTexts(purpose: .regenerated, profiles: 1)
        XCTAssertNil(regenerated.step)
        XCTAssertNil(regenerated.footer)
        XCTAssertEqual(regenerated.title, "Your new recovery key")
        XCTAssertTrue(regenerated.message.contains("old key no longer works"), regenerated.message)
        XCTAssertEqual(regenerated.confirm, "Done")
        XCTAssertTrue(regenerated.needsSavedConfirmation, "a new key must be stored")

        let viewed = RecoveryKeyTexts(purpose: .viewed, profiles: 1)
        XCTAssertNil(viewed.step)
        XCTAssertNil(viewed.footer)
        XCTAssertEqual(viewed.title, "Your recovery key")
        XCTAssertEqual(viewed.confirm, "Done")
        XCTAssertFalse(viewed.needsSavedConfirmation)
    }
}
#endif
