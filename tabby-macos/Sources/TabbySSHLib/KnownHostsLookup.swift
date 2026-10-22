#if os(macOS)
import CLibSSH
import CryptoKit
import Foundation

/// Reads OpenSSH known_hosts files for the keys recorded for a host (plain and hashed
/// `|1|salt|hash` entries; `@revoked` and `@cert-authority` lines are skipped).
enum KnownHostsLookup {
    struct Entry: Equatable {
        var type: String
        var fingerprint: String
    }

    static func fingerprints(host: String, port: Int, files: [String]) -> [Entry] {
        let name = port == 22 ? host : "[\(host)]:\(port)"
        var result: [Entry] = []
        for file in files {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard fields.count >= 3, !fields[0].hasPrefix("#"), !fields[0].hasPrefix("@") else { continue }
                guard matches(fields[0], name) else { continue }
                if let fingerprint = fingerprint(type: fields[1], base64: fields[2]) {
                    result.append(Entry(type: fields[1], fingerprint: fingerprint))
                }
            }
        }
        return result
    }

    static func matches(_ field: String, _ name: String) -> Bool {
        if field.hasPrefix("|1|") {
            let parts = field.split(separator: "|")
            guard parts.count == 3, let salt = Data(base64Encoded: String(parts[1])), let hash = Data(base64Encoded: String(parts[2])) else {
                return false
            }
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
            return Data(mac) == hash
        }
        return field.split(separator: ",").contains { $0 == name }
    }

    static func fingerprint(type: String, base64: String) -> String? {
        var key: ssh_key?
        guard ssh_pki_import_pubkey_base64(base64, ssh_key_type_from_name(type), &key) == SSH_OK, let key else { return nil }
        defer { ssh_key_free(key) }
        return SSHConnection.fingerprint(key)
    }
}
#endif
