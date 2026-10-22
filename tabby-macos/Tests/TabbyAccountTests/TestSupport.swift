import Foundation
import TabbySyncProtocol
@testable import TabbyAccount

typealias FakeSyncServer = InMemorySyncServer

/// Small scrypt parameters so tests run fast.
let testKDF = KDFParams(n: 1024, r: 8, p: 1, salt: Data(repeating: 7, count: 16))
let testDevice = DeviceInfo(name: "Test Mac", model: "Mac15,3", os: "macOS 27.0")
