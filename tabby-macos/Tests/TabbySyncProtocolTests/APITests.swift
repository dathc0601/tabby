import XCTest
import TabbySyncProtocol

final class APITests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_790_000_000.5)
    let kdf = KDFParams(n: 1024, r: 8, p: 1, salt: Data([1, 2, 3]))
    let device = DeviceInfo(name: "Studio MacBook Pro", model: "Mac15,3", os: "macOS 15.1")

    func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try SyncCoding.encoder.encode(value), as: UTF8.self)
    }

    func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let decoded = try SyncCoding.decoder.decode(T.self, from: SyncCoding.encoder.encode(value))
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    func testPaths() {
        XCTAssertEqual(APIPath.accountKDF, "/v1/account/kdf")
        XCTAssertEqual(APIPath.account, "/v1/account")
        XCTAssertEqual(APIPath.accountPassword, "/v1/account/password")
        XCTAssertEqual(APIPath.accountRecovery, "/v1/account/recovery")
        XCTAssertEqual(APIPath.session, "/v1/session")
        XCTAssertEqual(APIPath.sessionRecovery, "/v1/session/recovery")
        XCTAssertEqual(APIPath.vault, "/v1/vault")
        XCTAssertEqual(APIPath.vaultHead, "/v1/vault/head")
        XCTAssertEqual(APIPath.devices, "/v1/devices")
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
        XCTAssertEqual(APIPath.device(id), "/v1/devices/6F9619FF-8B86-D011-B42D-00CF4FC964FF")
        XCTAssertEqual(APIPath.ifMatchHeader, "If-Match")
    }

    func testRegisterRequestJSONUsesBase64() throws {
        let request = RegisterRequest(
            email: "a@b.c", authKey: Data([0xFF]), recoveryAuthKey: Data([0xFE]), kdf: kdf,
            wrappedByPassword: Data([1]), wrappedByRecovery: Data([2]), device: device)
        XCTAssertEqual(try json(request), #"{"authKey":"/w==","device":{"model":"Mac15,3","name":"Studio MacBook Pro","os":"macOS 15.1"},"email":"a@b.c","kdf":{"n":1024,"name":"scrypt","p":1,"r":8,"salt":"AQID"},"recoveryAuthKey":"/g==","wrappedByPassword":"AQ==","wrappedByRecovery":"Ag=="}"#)
        try roundTrip(request)
    }

    func testVaultJSON() throws {
        let deviceID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!
        let vault = VaultDTO(revision: 3, modifiedAt: date, deviceId: deviceID, ciphertext: Data([9, 9]))
        XCTAssertEqual(try json(vault), #"{"ciphertext":"CQk=","deviceId":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","modifiedAt":"2026-09-21T14:13:20.500Z","revision":3}"#)
        XCTAssertEqual(vault.head, VaultHead(revision: 3, modifiedAt: date, deviceId: deviceID))
        try roundTrip(vault)
        try roundTrip(VaultPutRequest(ciphertext: Data([1])))
        try roundTrip(VaultPutResponse(revision: 4, modifiedAt: date))
    }

    func testPasswordChangeCarriesExactlyOneProof() throws {
        let byPassword = PasswordChangeRequest(
            authKey: Data([1]), newAuthKey: Data([2]), newKdf: kdf, newWrappedByPassword: Data([3]))
        XCTAssertFalse(try json(byPassword).contains("recoveryAuthKey"), "nil proofs are left out")
        try roundTrip(byPassword)
        let byRecovery = PasswordChangeRequest(
            recoveryAuthKey: Data([1]), newAuthKey: Data([2]), newKdf: kdf, newWrappedByPassword: Data([3]))
        try roundTrip(byRecovery)
    }

    func testResponsesRoundTrip() throws {
        let account = AccountDTO(id: UUID(), email: "a@b.c", createdAt: date, kdf: kdf,
                                 wrappedByPassword: Data([1, 2]), recoveryUpdatedAt: date)
        let deviceDTO = DeviceDTO(id: UUID(), name: "Mac", model: "Mac15,3", os: "macOS 15",
                                  createdAt: date, lastSeenAt: date, isCurrent: true)
        try roundTrip(KDFResponse(kdf: kdf))
        try roundTrip(SessionRequest(email: "a@b.c", authKey: Data([1]), device: device))
        try roundTrip(RecoverySessionRequest(email: "a@b.c", recoveryAuthKey: Data([1]), device: device))
        try roundTrip(SessionResponse(token: "t", account: account, device: deviceDTO))
        try roundTrip(RecoverySessionResponse(token: "t", account: account, device: deviceDTO, wrappedByRecovery: Data([7])))
        try roundTrip(RecoveryRotateRequest(authKey: Data([1]), newRecoveryAuthKey: Data([2]), newWrappedByRecovery: Data([3])))
        try roundTrip(DeleteAccountRequest(authKey: Data([1])))
        try roundTrip(ErrorDTO(error: ErrorDTO.Code.conflict, message: "Revision 3 is current"))
        try roundTrip([deviceDTO])
    }

    func testLimits() {
        XCTAssertEqual(APILimits.maxVaultBodyBytes, 25 * 1024 * 1024)
        XCTAssertEqual(APILimits.maxBodyBytes, 64 * 1024)
    }
}
