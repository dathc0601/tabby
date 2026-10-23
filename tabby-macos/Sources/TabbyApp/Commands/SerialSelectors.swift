#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbySerial

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
        guard !ports.isEmpty else {
            toasts.show(ToastCenter.Toast(symbol: "memorychip", tint: .danger, title: "No serial ports found",
                                          detail: "Plug in a device, or type its path with quick connect."))
            return
        }
        let items = ports.map { port in
            SelectorItem(id: port.path, title: port.deviceName, group: port.isInternal ? "Built in" : "Ports",
                         subtitle: port.description ?? port.path, icon: "memorychip") { chosen(port.path) }
        }
        SelectorPanel.present(over: window, placeholder: "Serial port", items: items) { query in
            // A path typed by hand (a device the list doesn't show, a pty).
            guard query.hasPrefix("/dev/") else { return [] }
            return [SelectorItem(id: "path", title: "Use \(query)", icon: "memorychip") { chosen(query) }]
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
