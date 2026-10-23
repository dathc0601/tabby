#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbySerial
import TabbyTerminal

/// The chip's "Baud rate" button: the rate of an open port changes at once, and the tab keeps
/// it (Tabby's `SerialTabComponent.changeBaudRate`).
@MainActor
enum SerialChip {
    static func serialSession(of pane: TerminalPane) -> SerialSession? {
        ((pane.session as? ProcessedSession)?.inner ?? pane.session) as? SerialSession
    }

    static func changeBaudRate(of pane: TerminalPane, to rate: Int) throws {
        guard let session = serialSession(of: pane) else { return }
        try session.changeBaudRate(rate)
        pane.updateOption("baudrate", .int(rate))
    }

    static func askBaudRate(for pane: TerminalPane) {
        let controller = WindowManager.shared.controllers.first { c in c.model.tabs.contains { $0.panes[pane.id] != nil } }
        controller?.chooseBaudRate { [weak controller] rate in
            do {
                try changeBaudRate(of: pane, to: rate)
            } catch {
                controller?.toasts.show(ToastCenter.Toast(symbol: "exclamationmark.circle.fill", tint: .danger,
                                                          title: "Could not change the baud rate",
                                                          detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }
}

/// The selectors of serial tabs: which port, which baud rate (Tabby asks the rate in
/// `getNewTabParameters`), and "Show Serial connections" (the `serial` hotkey).
extension MainWindowController {
    func completeSerialProfile(_ profile: Profile, missing: [SerialProfileProvider.Parameter],
                               completion: @escaping (Profile?) -> Void) {
        let askRate: (Profile) -> Void = { [weak self] withPort in
            guard missing.contains(.baudRate) else { completion(withPort); return }
            self?.chooseBaudRate { rate in completion(SerialProfileProvider.completing(withPort, baudRate: rate)) }
        }
        if missing.contains(.port) {
            chooseSerialPort { port in askRate(SerialProfileProvider.completing(profile, port: port)) }
        } else {
            askRate(profile)
        }
    }

    /// One row per port on this Mac, external ones first. Picking one calls `chosen`; closing
    /// the selector opens nothing.
    func chooseSerialPort(_ chosen: @escaping (String) -> Void) {
        let ports = AppServices.shared.serialPorts.ports
        let items = ports.map { port in
            SelectorItem(id: port.path, title: port.deviceName, group: port.isInternal ? "Built in" : "Ports",
                         subtitle: port.description ?? port.path, icon: "memorychip") { chosen(port.path) }
        }
        SelectorPanel.present(over: window, placeholder: "Serial port or a device path", items: items) { query in
            // A path typed by hand: a device the list doesn't show, a link to one.
            guard query.hasPrefix("/") || query.hasPrefix("~") else { return [] }
            let path = (query as NSString).expandingTildeInPath
            return [SelectorItem(id: "path", title: "Use \(path)", icon: "memorychip") { chosen(path) }]
        }
    }

    /// Tabby's standard rates with 115200 selected, plus any rate typed in.
    func chooseBaudRate(_ chosen: @escaping (Int) -> Void) {
        let items = BaudRates.standard.map { rate in
            SelectorItem(id: "\(rate)", title: "\(rate)", icon: "speedometer") { chosen(rate) }
        }
        let preselected = BaudRates.standard.firstIndex(of: BaudRates.quickConnectDefault) ?? 0
        SelectorPanel.present(over: window, placeholder: "Baud rate", items: items, initialSelection: preselected) { query in
            guard let rate = Int(query.trimmingCharacters(in: .whitespaces)), rate > 0,
                  !BaudRates.standard.contains(rate) else { return [] }
            return [SelectorItem(id: "custom", title: "Use custom rate \u{201C}\(rate)\u{201D}", icon: "speedometer") { chosen(rate) }]
        }
    }

    /// "Show Serial connections": saved serial profiles, then a profile per port.
    func showSerialSelector() {
        let registry = AppServices.shared.profiles
        let provider = registry.provider(for: "serial")
        let profiles = registry.allProfiles().filter { $0.type == "serial" }
        let items = profiles.enumerated().map { index, p in
            SelectorItem(id: "s\(index)", title: p.name, group: p.isBuiltin ? (p.isTemplate ? "" : "Ports") : "Saved profiles",
                         subtitle: provider?.description(for: p) ?? "", icon: ProfileIcons.symbol(for: p.icon ?? "fas fa-microchip"),
                         color: p.color) { [weak self] in
                self?.model.openTab(profile: p)
            }
        }
        SelectorPanel.present(over: window, placeholder: "Serial port or profile", items: items) { [weak self] query in
            guard let profile = provider?.quickConnect(query), query.hasPrefix("/") else { return [] }
            return [SelectorItem(id: "qc", title: query, group: "Quick connect", icon: "bolt") { self?.model.openTab(profile: profile) }]
        }
    }
}
#endif
