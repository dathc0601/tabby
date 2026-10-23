import XCTest
@testable import TabbyCore

final class SSHTests: XCTestCase {
    let sampleConfig = """
    # global
    ServerAliveInterval 30
    Host bastion
        HostName bastion.example.com
        User me
        Port 2222
        IdentityFile ~/.ssh/id_bastion
    Host app-* !app-legacy
        User deploy
    Host prod web
        HostName 10.1.2.3
        ProxyJump bastion
        LocalForward 8080 localhost:80
        DynamicForward 1080
        ForwardAgent yes
        User=ops
    Match host foo
        User nobody
    """

    func testParse() {
        let entries = SSHConfigParser.parse(sampleConfig)
        XCTAssertEqual(entries.map(\.alias), ["bastion", "prod", "web"])
        XCTAssertEqual(entries[0].first("port"), "2222")
        XCTAssertEqual(entries[0].first("serveraliveinterval"), "30")
        XCTAssertEqual(entries[1].first("user"), "ops")
    }

    func testProfilesFromConfig() {
        let profiles = SSHConfigParser.profiles(from: SSHConfigParser.parse(sampleConfig), homeDirectory: "/Users/me")
        let bastion = SSHOptions(profiles[0].options)
        XCTAssertEqual(profiles[0].id, "ssh:ssh-config:bastion")
        XCTAssertEqual(bastion.host, "bastion.example.com")
        XCTAssertEqual(bastion.port, 2222)
        XCTAssertEqual(bastion.privateKeys, ["/Users/me/.ssh/id_bastion"])
        XCTAssertEqual(bastion.keepaliveInterval, 30000)
        let prod = SSHOptions(profiles[1].options)
        XCTAssertEqual(prod.jumpHost, "ssh:ssh-config:bastion")
        XCTAssertTrue(prod.agentForward)
        XCTAssertEqual(prod.forwardedPorts.map(\.type), [.local, .dynamic])
        XCTAssertEqual(prod.forwardedPorts[0].targetAddress, "localhost")
        XCTAssertEqual(prod.forwardedPorts[0].targetPort, 80)
        XCTAssertEqual(prod.forwardedPorts[1].port, 1080)
    }

    func paths() -> SSHConfigGenerator.Paths {
        .init(knownHostsFile: "/tmp/kh", extraKnownHostsFiles: ["/Users/me/.ssh/known_hosts"],
              controlDirectory: "/tmp/cm", localCommand: "/App/askpass --connected 42")
    }

    func testGenerateBasic() throws {
        let gen = SSHConfigGenerator(paths: paths())
        let o = SSHOptions(["host": "example.com", "user": "me", "port": 2200, "auth": "password",
                            "privateKeys": ["file:///Users/me/key with space"], "x11": true, "skipBanner": true,
                            "forwardedPorts": [["type": "Remote", "host": "0.0.0.0", "port": 9000, "targetAddress": "localhost", "targetPort": 3000]]])
        let out = try gen.generate(o, jumpHostResolver: { _ in nil })
        XCTAssertEqual(out.alias, "tabby-target")
        let c = out.config
        XCTAssertTrue(c.contains("    HostName example.com"), c)
        XCTAssertTrue(c.contains("    Port 2200"))
        XCTAssertTrue(c.contains("    User me"))
        XCTAssertTrue(c.contains("    IdentityFile \"/Users/me/key with space\""), c)
        XCTAssertTrue(c.contains("    PreferredAuthentications password,keyboard-interactive"))
        XCTAssertTrue(c.contains("    PubkeyAuthentication no"))
        XCTAssertTrue(c.contains("    ServerAliveInterval 5"))
        XCTAssertTrue(c.contains("    ForwardX11 yes"))
        XCTAssertTrue(c.contains("    LogLevel ERROR"))
        XCTAssertTrue(c.contains("    RemoteForward 0.0.0.0:9000 localhost:3000"))
        XCTAssertTrue(c.contains("    ControlMaster auto"))
        XCTAssertTrue(c.contains("    ControlPath /tmp/cm/%C"))
        XCTAssertTrue(c.contains("    LocalCommand /App/askpass --connected 42"))
        XCTAssertTrue(c.contains("    UserKnownHostsFile /tmp/kh /Users/me/.ssh/known_hosts"))
        XCTAssertTrue(c.contains("    StrictHostKeyChecking ask"))
    }

    func testJumpChain() throws {
        let gen = SSHConfigGenerator(paths: paths(), verifyHostKeys: false)
        let hops: [String: SSHOptions] = [
            "b1": SSHOptions(["host": "b1.example", "user": "a", "jumpHost": "b2"]),
            "b2": SSHOptions(["host": "b2.example", "user": "b", "socksProxyHost": "127.0.0.1", "socksProxyPort": 1080]),
        ]
        let out = try gen.generate(SSHOptions(["host": "target", "jumpHost": "b1"]), jumpHostResolver: { hops[$0] })
        let c = out.config
        XCTAssertTrue(c.contains("Host tabby-target\n"))
        XCTAssertTrue(c.contains("Host tabby-hop-0\n    HostName b1.example"), c)
        XCTAssertTrue(c.contains("Host tabby-hop-1\n    HostName b2.example"), c)
        XCTAssertTrue(c.contains("ProxyJump tabby-hop-0"))
        XCTAssertTrue(c.contains("ProxyJump tabby-hop-1"))
        XCTAssertTrue(c.contains("ProxyCommand /usr/bin/nc -X 5 -x 127.0.0.1:1080 %h %p"))
        XCTAssertTrue(c.contains("StrictHostKeyChecking no"))
        XCTAssertEqual(c.components(separatedBy: "    LocalCommand ").count, 2, "only the target runs LocalCommand")

        let loop: [String: SSHOptions] = ["x": SSHOptions(["host": "x", "jumpHost": "y"]), "y": SSHOptions(["host": "y", "jumpHost": "x"])]
        XCTAssertThrowsError(try gen.generate(SSHOptions(["host": "t", "jumpHost": "x"]), jumpHostResolver: { loop[$0] }))
        XCTAssertThrowsError(try gen.generate(SSHOptions(["host": ""]), jumpHostResolver: { _ in nil }))
    }

    func testAskpassClassifier() {
        XCTAssertEqual(AskpassPrompt.classify("me@example.com's password: ", kind: nil), .password(user: "me", host: "example.com"))
        XCTAssertEqual(AskpassPrompt.classify("(me@example.com) Password: ", kind: nil), .password(user: "me", host: "example.com"))
        XCTAssertEqual(AskpassPrompt.classify("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ", kind: nil),
                       .passphrase(keyPath: "/Users/me/.ssh/id_ed25519"))
        let hk = """
        The authenticity of host 'example.com (93.184.216.34)' can't be established.
        ED25519 key fingerprint is SHA256:abcDEF123+/xyz=.
        This key is not known by any other names.
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        guard case let .hostKey(host, type, fp, _) = AskpassPrompt.classify(hk, kind: "confirm") else { return XCTFail() }
        XCTAssertEqual(host, "example.com (93.184.216.34)")
        XCTAssertEqual(type, "ED25519")
        XCTAssertEqual(fp, "SHA256:abcDEF123+/xyz=")
        XCTAssertEqual(AskpassPrompt.classify("Verification code: ", kind: nil), .secret(message: "Verification code:"))
        XCTAssertEqual(AskpassPrompt.classify("Allow use of key?", kind: "confirm"), .confirm(message: "Allow use of key?"))
        XCTAssertEqual(AskpassPrompt.classify("Confirm user presence", kind: "none"), .information(message: "Confirm user presence"))
    }
}

final class UtilTests: XCTestCase {
    func testSlug() {
        XCTAssertEqual(Slug.make("My Shell"), "My-Shell")
        XCTAssertEqual(Slug.make("/bin/zsh"), "binzsh")
        XCTAssertEqual(Slug.make("prod (eu)!"), "prod-eu")
    }

    func testFuzzy() {
        let items = ["Split to the right", "Settings", "Show profile selector", "New tab"]
        XCTAssertEqual(FuzzyMatcher.filter(items, query: "set", text: { $0 }).first, "Settings")
        XCTAssertEqual(FuzzyMatcher.filter(items, query: "spr", text: { $0 }).first, "Split to the right")
        XCTAssertTrue(FuzzyMatcher.filter(items, query: "zzz", text: { $0 }).isEmpty)
        XCTAssertEqual(FuzzyMatcher.filter(items, query: "", text: { $0 }), items)
    }
}
