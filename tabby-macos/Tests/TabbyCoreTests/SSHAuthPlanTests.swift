import XCTest
@testable import TabbyCore

/// The library backend's authentication order, ported from Tabby's `ssh.ts` (`init`,
/// `populateStoredPasswordsForResolvedUsername`) and `authMethodSelection.ts` with its tests.
final class SSHAuthPlanTests: XCTestCase {
    private func steps(auth: SSHAuthMethod? = nil, privateKeys: [String] = [], defaults: [String] = [],
                       agent: Bool = false, files: Set<String> = [], profilePassword: String? = nil,
                       stored: String? = nil) -> [SSHAuthStep] {
        SSHAuthPlan.steps(auth: auth, host: "prod.example.com", user: "deploy", privateKeys: privateKeys,
                          defaultIdentities: defaults, agentAvailable: agent, fileExists: { files.contains($0) },
                          profilePassword: profilePassword, storedPassword: stored)
    }

    // MARK: Building the list

    func testAutomaticTriesEverythingInTabbysOrder() {
        let list = steps(privateKeys: ["~/.ssh/deploy"], agent: true, files: ["~/.ssh/deploy.pub"], stored: "s3cret")
        XCTAssertEqual(list, [
            .none,
            .agent(publicKeyFile: "~/.ssh/deploy.pub"),
            .agent(publicKeyFile: nil),
            .publicKey(file: "~/.ssh/deploy"),
            .keyboardInteractive(savedPassword: "s3cret"),
            .savedPassword("s3cret"),
            .promptPassword,
        ])
    }

    func testAKeyWithoutAPublicHalfIsNotAnAgentIdentity() {
        let list = steps(privateKeys: ["~/.ssh/deploy", "~/.ssh/ci.pub"], agent: true, files: ["~/.ssh/ci.pub"])
        XCTAssertEqual(list.filter { $0.method == "publickey" }, [
            .agent(publicKeyFile: "~/.ssh/ci.pub"), .agent(publicKeyFile: nil),
            .publicKey(file: "~/.ssh/deploy"), .publicKey(file: "~/.ssh/ci.pub"),
        ])
    }

    func testWithoutKeysTheDefaultIdentitiesAreTried() {
        XCTAssertEqual(steps(defaults: ["/home/.ssh/id_ed25519", "/home/.ssh/id_rsa"]).filter { $0.method == "publickey" },
                       [.publicKey(file: "/home/.ssh/id_ed25519"), .publicKey(file: "/home/.ssh/id_rsa")])
    }

    func testKeyPathsExpandHostAndUser() {
        XCTAssertEqual(steps(privateKeys: ["~/.ssh/%r@%h"]).filter { $0.method == "publickey" },
                       [.publicKey(file: "~/.ssh/deploy@prod.example.com")])
    }

    func testAProfilePasswordComesFirstThenADifferentStoredOne() {
        XCTAssertEqual(steps(profilePassword: "inline", stored: "keychain"), [
            .none,
            .savedPassword("inline"),
            .keyboardInteractive(savedPassword: "inline"),
            .keyboardInteractive(savedPassword: "keychain"),
            .savedPassword("keychain"),
            .promptPassword,
        ])
        XCTAssertEqual(steps(profilePassword: "same", stored: "same"), [
            .none, .savedPassword("same"), .keyboardInteractive(savedPassword: "same"),
            .keyboardInteractive(savedPassword: nil), .promptPassword,
        ], "the same password is not tried twice")
    }

    func testAChosenMethodLimitsTheList() {
        XCTAssertEqual(steps(auth: .password, privateKeys: ["k"], agent: true, stored: "pw"),
                       [.none, .savedPassword("pw"), .promptPassword])
        XCTAssertEqual(steps(auth: .keyboardInteractive, privateKeys: ["k"], stored: "pw"),
                       [.none, .keyboardInteractive(savedPassword: "pw")])
        XCTAssertEqual(steps(auth: .publicKey, privateKeys: ["k"], agent: true, stored: "pw"),
                       [.none, .publicKey(file: "k")])
        XCTAssertEqual(steps(auth: .agent, privateKeys: ["k"], agent: true, files: ["k.pub"], stored: "pw"),
                       [.none, .agent(publicKeyFile: "k.pub"), .agent(publicKeyFile: nil)])
        XCTAssertEqual(steps(auth: .agent, agent: false), [.none], "no agent, nothing but none")
    }

    // MARK: Choosing the next step (authMethodSelection.test.ts)

    func testContinuesWithKeyboardInteractiveAfterPartialPublicKeySuccess() {
        var plan = SSHAuthPlan(steps: [.publicKey(file: "k")], allowed: ["publickey"])
        XCTAssertEqual(plan.next(), .publicKey(file: "k"))
        plan.failed(partialSuccess: true, allowedMethods: ["keyboard-interactive"])
        XCTAssertEqual(plan.next(), .keyboardInteractive(savedPassword: nil))
    }

    func testDoesNotAddKeyboardInteractiveAfterAFullPublicKeyRejection() {
        var plan = SSHAuthPlan(steps: [], allowed: [])
        plan.failed(partialSuccess: false, allowedMethods: ["keyboard-interactive"])
        XCTAssertNil(plan.next())
    }

    func testSelectsPublicKeyForAPublicKeyOnlyServer() {
        var plan = SSHAuthPlan(steps: [.publicKey(file: "k"), .keyboardInteractive(savedPassword: nil)], allowed: ["publickey"])
        XCTAssertEqual(plan.next(), .publicKey(file: "k"))
    }

    func testSelectsKeyboardInteractiveWhenItIsTheOnlyAdvertisedMethod() {
        var plan = SSHAuthPlan(steps: [.publicKey(file: "k"), .keyboardInteractive(savedPassword: nil)], allowed: ["keyboard-interactive"])
        XCTAssertEqual(plan.next(), .keyboardInteractive(savedPassword: nil))
    }

    func testSelectsOnlyMethodsAdvertisedByTheServer() {
        var plan = SSHAuthPlan(steps: [.promptPassword, .publicKey(file: "k"), .keyboardInteractive(savedPassword: nil)],
                               allowed: ["keyboard-interactive"])
        XCTAssertEqual(plan.next(), .keyboardInteractive(savedPassword: nil))
        XCTAssertNil(plan.next(), "each step is tried once")
    }

    func testStopsWhenItRunsOutOfMethods() {
        var plan = SSHAuthPlan(steps: [], allowed: [])
        plan.failed(partialSuccess: false, allowedMethods: [])
        XCTAssertNil(plan.next())
    }

    func testTriesEverythingWhenTheServerAdvertisesNothing() {
        var plan = SSHAuthPlan(steps: [.publicKey(file: "k"), .promptPassword], allowed: [])
        XCTAssertEqual(plan.next(), .publicKey(file: "k"))
    }

    func testAnEmptyListFromTheServerKeepsThePreviousOne() {
        var plan = SSHAuthPlan(steps: [.publicKey(file: "a"), .promptPassword, .publicKey(file: "b")], allowed: ["publickey"])
        XCTAssertEqual(plan.next(), .publicKey(file: "a"))
        plan.failed(partialSuccess: false, allowedMethods: [])
        XCTAssertEqual(plan.next(), .publicKey(file: "b"), "Tabby keeps methodsLeft when the failure lists none")
    }
}
