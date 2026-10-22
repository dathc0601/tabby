#if os(macOS)
import CLibSSH

/// The libssh library itself.
enum LibSSH {
    /// `ssh_version(0)`: the linked library's version, e.g. "0.12.2/openssl/zlib".
    static var version: String {
        ssh_version(0).map { String(cString: $0) } ?? ""
    }

    /// libssh's global state; idempotent. Sessions call it before their first use.
    static let initialised: Bool = ssh_init() == SSH_OK
}
#endif
