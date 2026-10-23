import Foundation

/// Port of `ConfigService.migrate` (`tabby-core/src/services/config.service.ts`), so configs
/// written by any Tabby version load correctly.
public enum Migrations {
    public static let latestVersion = 8

    public static func migrate(_ config: inout ConfigValue) {
        var version = config["version"]?.intValue ?? 0

        if version < 1 {
            // Single privateKey -> privateKeys[]
            if var connections = config.value(at: "ssh.connections")?.arrayValue {
                for i in connections.indices {
                    if let key = connections[i]["privateKey"]?.stringValue, !key.isEmpty {
                        connections[i]["privateKeys"] = .array([.string(key)])
                    }
                    connections[i]["privateKey"] = nil
                }
                config.setValue(.array(connections), at: "ssh.connections")
            }
            version = 1
        }
        if version < 2 {
            // terminal.profiles -> profiles (type local); terminal.recoverTabs -> recoverTabs
            if let legacy = config.value(at: "terminal.recoverTabs") {
                config["recoverTabs"] = legacy
                config.setValue(nil, at: "terminal.recoverTabs")
            }
            var profiles = config["profiles"]?.arrayValue ?? []
            for p in config.value(at: "terminal.profiles")?.arrayValue ?? [] {
                var profile: ConfigValue = .object([:])
                profile["type"] = "local"
                profile["name"] = p["name"] ?? "Shell" // l10n-ignore: written into config.yaml, as Tabby does
                if let icon = p["icon"] { profile["icon"] = icon }
                if let color = p["color"] { profile["color"] = color }
                profile["options"] = p["sessionOptions"] ?? .emptyObject
                profiles.append(profile)
            }
            if config.value(at: "terminal.profiles") != nil {
                config.setValue(nil, at: "terminal.profiles")
                config["profiles"] = .array(profiles)
            }
            version = 2
        }
        if version < 3 {
            // ssh.connections / serial.connections -> profiles; jumpHost name -> id
            var profiles = config["profiles"]?.arrayValue ?? []
            var nameToId: [String: String] = [:]
            for (type, path) in [("ssh", "ssh.connections"), ("serial", "serial.connections")] {
                for c in config.value(at: path)?.arrayValue ?? [] {
                    let name = c["name"]?.stringValue ?? "Connection" // l10n-ignore: written into config.yaml, as Tabby does
                    let id = "\(type):\(Slug.make(name)):\(UUID().uuidString.lowercased())"
                    nameToId[name] = id
                    var options = c
                    options["name"] = nil
                    options["group"] = nil
                    var profile: ConfigValue = .object([:])
                    profile["id"] = .string(id)
                    profile["type"] = .string(type)
                    profile["name"] = .string(name)
                    if let g = c["group"] { profile["group"] = g }
                    profile["options"] = options
                    profiles.append(profile)
                }
                if config.value(at: path) != nil { config.setValue(nil, at: path) }
            }
            for i in profiles.indices {
                if let jump = profiles[i].value(at: "options.jumpHost")?.stringValue, let id = nameToId[jump] {
                    profiles[i].setValue(.string(id), at: "options.jumpHost")
                }
            }
            if !profiles.isEmpty || config["profiles"] != nil { config["profiles"] = .array(profiles) }
            version = 3
        }
        if version < 4 {
            // Ensure every profile has an id.
            if var profiles = config["profiles"]?.arrayValue {
                for i in profiles.indices where (profiles[i]["id"]?.stringValue ?? "").isEmpty {
                    let type = profiles[i]["type"]?.stringValue ?? "local"
                    let name = profiles[i]["name"]?.stringValue ?? "profile"
                    profiles[i]["id"] = .string("\(type):custom:\(Slug.make(name)):\(UUID().uuidString.lowercased())")
                }
                config["profiles"] = .array(profiles)
            }
            version = 4
        }
        if version < 5 {
            // Group names -> groups[] with ids.
            if var profiles = config["profiles"]?.arrayValue {
                var groups = config["groups"]?.arrayValue ?? []
                var groupIds: [String: String] = [:]
                for g in groups {
                    if let name = g["name"]?.stringValue, let id = g["id"]?.stringValue { groupIds[name] = id }
                }
                for i in profiles.indices {
                    guard let name = profiles[i]["group"]?.stringValue, !name.isEmpty else { continue }
                    if groups.contains(where: { $0["id"]?.stringValue == name }) { continue }
                    let id = groupIds[name] ?? UUID().uuidString.lowercased()
                    if groupIds[name] == nil {
                        groupIds[name] = id
                        groups.append(.object(["id": .string(id), "name": .string(name)]))
                    }
                    profiles[i]["group"] = .string(id)
                }
                config["profiles"] = .array(profiles)
                if !groups.isEmpty { config["groups"] = .array(groups) }
            }
            version = 5
        }
        if version < 6 {
            // clearServiceMessagesOnConnect moved from ssh/serial options to profile level.
            if var profiles = config["profiles"]?.arrayValue {
                for i in profiles.indices {
                    if let v = profiles[i].value(at: "options.clearServiceMessagesOnConnect") {
                        profiles[i]["clearServiceMessagesOnConnect"] = v
                        profiles[i].setValue(nil, at: "options.clearServiceMessagesOnConnect")
                    }
                }
                config["profiles"] = .array(profiles)
            }
            version = 6
        }
        if version < 7 {
            // Default config sync host/token were cleared upstream; nothing to carry over.
            version = 7
        }
        if version < 8 {
            // SSH compression forced off.
            if var profiles = config["profiles"]?.arrayValue {
                for i in profiles.indices where profiles[i]["type"]?.stringValue == "ssh" {
                    if profiles[i].value(at: "options.algorithms.compression") != nil {
                        profiles[i].setValue(["none"], at: "options.algorithms.compression")
                    }
                }
                config["profiles"] = .array(profiles)
            }
            version = 8
        }
        config["version"] = .int(version)
    }
}
