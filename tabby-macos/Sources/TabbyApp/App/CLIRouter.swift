#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbyCLIKit

/// Carries out `tabby …` commands and links (phase 5), as Tabby's `CLIHandler`s do:
/// `ProfileCLIHandler` (profile, recent, quickConnect), `TerminalCLIHandler` (open, run,
/// paste) and `OpenPathCLIHandler` (a bare path). Requests that arrive before the first window
/// exists wait (AppKit can hand over a link before `applicationDidFinishLaunching` is done).
@MainActor
final class CLIRouter {
    static let shared = CLIRouter()

    /// The window requests go to.
    var target: () -> MainWindowController = {
        WindowManager.shared.activeController ?? WindowManager.shared.newWindow(openDefaultTab: false)
    }
    /// Asks before `run` and `paste` (title, confirm button); tests answer.
    var confirm: (_ title: String, _ button: String, _ done: @escaping (Bool) -> Void) -> Void = { title, button, done in
        Prompts.confirm(in: NSApp.keyWindow, title: title, message: "", confirm: button, completion: done)
    }

    private var ready = false
    private var pending: [(CLIRequest, String)] = []
    var hasPendingRequests: Bool { !pending.isEmpty }

    func becomeReady() {
        ready = true
        let queued = pending
        pending = []
        for (request, cwd) in queued { handle(request, cwd: cwd) }
    }

    /// A link: tabbymac://, ssh:// or telnet://. False when it is none of them.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let request = TabbyURL.parse(url) else { return false }
        handle(request, cwd: NSHomeDirectory())
        return true
    }

    /// The app's own launch arguments (`swift run TabbyMacDev open ~/x`); a usage error is
    /// logged, not shown.
    func launchArguments(_ args: [String], cwd: String) {
        switch CLIArguments.parse(CLIArguments.appLaunchArguments(args)) {
        case .success(.request(let request)): handle(request, cwd: cwd)
        case .success: break
        case .failure(let error): NSLog("TabbyMac: ignoring launch arguments: \(error.message)")
        }
    }

    func handle(_ request: CLIRequest, cwd: String) {
        guard ready else { pending.append((request, cwd)); return }
        let controller = target()
        switch request {
        case let .open(directory):
            openDirectory(resolve(directory ?? cwd, against: cwd), in: controller)
        case let .run(command, runCwd):
            confirm(L("Run \"{command}\"?", ["command": command.joined(separator: " ")]), L("Run")) { ok in
                guard ok, let executable = command.first else { return }
                let options = LocalOptions(command: executable, args: Array(command.dropFirst()), cwd: runCwd, pauseAfterExit: true)
                controller.model.openTab(profile: Profile(type: "local", name: command.joined(separator: " "), options: options.configValue))
            }
        case let .profile(name):
            guard let profile = AppServices.shared.profiles.allProfiles(includeHidden: true).first(where: { $0.name == name }) else {
                return fail(L("No profile named “{name}”", ["name": name]), in: controller)
            }
            controller.open(profile, switchActivePane: false)
        case let .paste(text, escape):
            guard let text else { return }
            let prepared = escape ? ShellWords.quote(text) : text
            confirm(L("Paste \"{text}\"?", ["text": prepared]), L("Paste")) { ok in
                if ok { controller.send(prepared) }
            }
        case let .recent(index):
            let recents = AppServices.shared.profiles.recents.load()
            guard recents.indices.contains(index) else { return fail(L("No recent profile {index}", ["index": index]), in: controller) }
            controller.open(recents[index], switchActivePane: false)
        case let .quickConnect(provider, query):
            guard let profile = AppServices.shared.profiles.quickConnect(query, providerId: provider) else {
                return fail(L("Cannot open “{query}” with {provider}", ["query": query, "provider": provider]), in: controller)
            }
            controller.open(profile, switchActivePane: false)
        case let .path(path):
            openPath(resolve(path, against: cwd), in: controller)
        }
        bringToFront(controller)
    }

    // MARK: Helpers

    /// Tabby: `path.resolve(event.cwd, argv.directory)`, without a trailing slash.
    private func resolve(_ path: String, against cwd: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (cwd as NSString).appendingPathComponent(expanded)
        let standard = (absolute as NSString).standardizingPath
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }

    private func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    private func openDirectory(_ path: String, in controller: MainWindowController) {
        guard isDirectory(path) else { return fail(L("No such directory {path}", ["path": path]), in: controller) }
        controller.model.openTab(cwd: path)
    }

    /// Tabby's `OpenPathCLIHandler`: a directory opens there; a `.sh` or `.command` script
    /// runs in the default profile, which stays open after it.
    private func openPath(_ path: String, in controller: MainWindowController) {
        if isDirectory(path) { return openDirectory(path, in: controller) }
        guard FileManager.default.fileExists(atPath: path), ["sh", "command"].contains((path as NSString).pathExtension) else {
            return fail(L("Cannot handle scripts of this type"), in: controller)
        }
        var profile = AppServices.shared.defaultProfile()
        var options = LocalOptions(profile.options)
        options.args.append(path)
        options.pauseAfterExit = true
        profile.options = options.configValue
        profile.name = (path as NSString).lastPathComponent
        controller.model.openTab(profile: profile, cwd: (path as NSString).deletingLastPathComponent)
    }

    private func fail(_ message: String, in controller: MainWindowController) {
        controller.toasts.show(ToastCenter.Toast(symbol: "exclamationmark.triangle", tint: .warning, title: message, detail: ""))
        bringToFront(controller)
    }

    private func bringToFront(_ controller: MainWindowController) {
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
