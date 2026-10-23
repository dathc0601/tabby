#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbyCLIKit

/// Which app opens ssh:// and telnet:// links, and where the `tabby` helper is (Settings ›
/// Application, phase 5). Making TabbyMac the handler is the user's choice: macOS asks them
/// to confirm it.
@MainActor
enum LinkHandlers {
    static let schemes = ["ssh", "telnet"]

    private static func handlerURL(for scheme: String) -> URL? {
        URL(string: "\(scheme)://localhost").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    /// The name of the app that opens `scheme://` links now.
    static func handlerName(for scheme: String) -> String? {
        handlerURL(for: scheme).map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
    }

    static var isDefault: Bool {
        schemes.allSatisfy { handlerURL(for: $0)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL }
    }

    /// Only the app bundle can register itself (`swift run` and tests have none).
    static var canChange: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func makeDefault(then done: @escaping () -> Void) {
        let group = DispatchGroup()
        for scheme in schemes {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { error in
                if let error { NSLog("TabbyMac: \(scheme):// handler not changed: \(error.localizedDescription)") }
                group.leave()
            }
        }
        group.notify(queue: .main, execute: done)
    }

    /// `Contents/MacOS/tabby` in the app; next to the executable for `swift run`.
    static var cliPath: String {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "tabby") { return url.path }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tabby").path
    }

    static var installCommand: String {
        "sudo ln -sf \(ShellWords.quote(cliPath)) /usr/local/bin/tabby" // l10n-ignore: a shell command
    }
}
#endif
