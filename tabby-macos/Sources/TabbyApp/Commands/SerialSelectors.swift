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

    /// The chip's popover for the open port (design C2): its device and the rate in use.
    static func popoverModel(for pane: TerminalPane) -> BaudRatePopoverModel? {
        guard let session = serialSession(of: pane) else { return nil }
        let device = SerialOptions(pane.profile.options).port.map { ($0 as NSString).lastPathComponent } ?? pane.profile.name
        return BaudRatePopoverModel(device: device, current: session.baudRate) { rate in apply(rate, to: pane) }
    }

    /// Changes the rate, or says why not in a toast of the pane's window (design C2b).
    static func apply(_ rate: Int, to pane: TerminalPane) {
        do {
            try changeBaudRate(of: pane, to: rate)
        } catch {
            let controller = WindowManager.shared.controllers.first { c in c.model.tabs.contains { $0.panes[pane.id] != nil } }
            controller?.toasts.show(ToastCenter.Toast(symbol: "exclamationmark.circle.fill", tint: .danger,
                                                      title: L("Could not change the baud rate"),
                                                      detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
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

    /// Asks for a port (design C4). Picking one calls `chosen`; closing opens nothing.
    func chooseSerialPort(_ chosen: @escaping (String) -> Void) {
        SelectorPanel.present(over: window, SerialSelectors.portSelector(ports: AppServices.shared.serialPorts.ports, chosen: chosen))
    }

    /// Asks for a baud rate (design C3).
    func chooseBaudRate(_ chosen: @escaping (Int) -> Void) {
        SelectorPanel.present(over: window, SerialSelectors.baudSelector(chosen: chosen))
    }

    /// "Show Serial connections" (design C5).
    func showSerialSelector() {
        let registry = AppServices.shared.profiles
        guard let provider = registry.provider(for: "serial") else { return }
        let profiles = registry.allProfiles().filter { $0.type == "serial" }
        SelectorPanel.present(over: window, SerialSelectors.connectionsSelector(profiles: profiles, provider: provider) { [weak self] in
            self?.model.openTab(profile: $0)
        })
    }
}

/// The serial selectors' contents (designs C3–C5).
@MainActor
enum SerialSelectors {
    /// One row per port: external ones under "Ports", the Mac's own ones dimmed under
    /// "Built in"; a typed path leads the list.
    static func portSelector(ports: [SerialPortInfo], chosen: @escaping (String) -> Void) -> SelectorConfig {
        let ordered = ports.filter { !$0.isInternal } + ports.filter(\.isInternal)
        let items = ordered.map { port in
            SelectorItem(id: port.path, title: port.deviceName, group: port.isInternal ? L("Built in") : L("Ports"),
                         subtitle: port.description ?? port.path, icon: "cable.connector", isDimmed: port.isInternal) { chosen(port.path) }
        }
        return SelectorConfig(placeholder: L("Serial port or a device path"), items: items, dynamicItems: { query in
            // A path typed by hand: a device the list doesn't show, a link to one.
            guard query.hasPrefix("/") || query.hasPrefix("~") else { return [] }
            let path = (query as NSString).expandingTildeInPath
            return [SelectorItem(id: "path", title: L("Use {path}", ["path": path]), icon: "pencil") { chosen(path) }]
        }, dynamicItemsFirst: true,
           emptyState: SelectorEmptyState(icon: "cable.connector", title: L("No ports found"), subtitle: L("Connect a device, or type its path")),
           trailingHint: nil)
    }

    /// Tabby's standard rates with 115200 selected, plus any rate typed in.
    static func baudSelector(chosen: @escaping (Int) -> Void) -> SelectorConfig {
        let items = BaudRates.standard.map { rate in
            SelectorItem(id: "\(rate)", title: "\(rate)", icon: "speedometer") { chosen(rate) }
        }
        let preselected = BaudRates.standard.firstIndex(of: BaudRates.quickConnectDefault) ?? 0
        return SelectorConfig(placeholder: L("Baud rate"), items: items, initialSelection: preselected, dynamicItems: { query in
            guard let rate = Int(query.trimmingCharacters(in: .whitespaces)), rate > 0,
                  !BaudRates.standard.contains(rate) else { return [] }
            return [SelectorItem(id: "custom", title: L("Use custom rate \u{201C}{rate}\u{201D}", ["rate": rate]), icon: "pencil") { chosen(rate) }]
        }, trailingHint: nil)
    }

    /// Saved serial profiles, then the "Serial connection" template, then a profile per port;
    /// a typed `path@rate` is a quick connect row first.
    static func connectionsSelector(profiles: [Profile], provider: ProfileProvider,
                                    open: @escaping (Profile) -> Void) -> SelectorConfig {
        let saved = profiles.filter { !$0.isBuiltin }
        let templates = profiles.filter { $0.isBuiltin && $0.isTemplate }
        let ports = profiles.filter { $0.isBuiltin && !$0.isTemplate }
        // Ids carry the position: a hand-edited config can have profiles without an id.
        let items = saved.enumerated().map { index, p in
            SelectorItem(id: "saved-\(index)-\(p.id)", title: p.name, group: L("Saved profiles"), subtitle: provider.description(for: p),
                         icon: ProfileIcons.symbol(for: p.icon ?? ProfileIcons.defaultIcon(forType: "serial")), color: p.color) { open(p) }
        } + templates.enumerated().map { index, p in
            SelectorItem(id: "template-\(index)-\(p.id)", title: p.name, subtitle: L("Asks for the port and baud rate"), icon: "plus") { open(p) }
        } + ports.enumerated().map { index, p in
            SelectorItem(id: "port-\(index)-\(p.id)", title: p.name, group: L("Ports"), subtitle: provider.description(for: p),
                         icon: ProfileIcons.symbol(for: p.icon ?? ProfileIcons.defaultIcon(forType: "serial")), color: p.color) { open(p) }
        }
        return SelectorConfig(placeholder: L("Serial port or profile"), items: items, dynamicItems: { query in
            guard query.hasPrefix("/"), let profile = provider.quickConnect(query) else { return [] }
            let o = SerialOptions(profile.options)
            let target = o.port.map { port in o.baudrate.map { L("{port} at {rate} baud", ["port": port, "rate": $0]) } ?? port } ?? query
            return [SelectorItem(id: "qc", title: L("Quick connect"), subtitle: target, icon: "bolt") { open(profile) }]
        }, dynamicItemsFirst: true, trailingHint: StartPageView.shortcut("serial").map { L("{shortcut} serial", ["shortcut": $0]) })
    }
}
#endif
