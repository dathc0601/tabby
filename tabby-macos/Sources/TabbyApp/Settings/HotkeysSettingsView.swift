#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// Lets the capture sheet pause the global hotkey monitor.
@MainActor
enum HotkeyCapture {
    static var manager: HotkeyManager?
}

/// Hotkeys page (Tabby's `HotkeySettingsTabComponent`, phase 2 design): filterable groups,
/// each binding a removable keycap, + to capture another, and a capture sheet that warns
/// about conflicts.
struct HotkeysSettingsView: View {
    @State private var filter = ""
    @State private var onlyChanged = false
    @State private var capturing: HotkeyCatalog.Entry?
    @Environment(\.chrome) private var chrome

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        let config = services.config
        let entries = HotkeyCatalog.entries.filter { entry in
            guard !onlyChanged || config.user.value(at: "hotkeys.\(entry.id)") != nil else { return false }
            let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
            guard !q.isEmpty else { return true }
            let keys = HotkeyBinding.bindings(from: config.value("hotkeys.\(entry.id)")).map { $0.symbolicDescription.lowercased() }
            return "\(entry.group) \(entry.name) \(entry.id) \(entry.groupTitle) \(entry.title)".lowercased().contains(q) || keys.contains { $0.contains(q) }
        }
        let groups = Dictionary(grouping: entries, by: \.group)
        let order = HotkeyCatalog.entries.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        SettingsPage(L("Hotkeys")) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(chrome.textMuted.color)
                    TextField(L("Filter by name or keys"), text: $filter).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(chrome.fill.color))
                RowPicker(selection: $onlyChanged) {
                    Text(L("All")).tag(false)
                    Text(L("Changed")).tag(true)
                }
                Spacer()
                Button(L("Restore defaults")) {
                    for entry in HotkeyCatalog.entries where config.user.value(at: "hotkeys.\(entry.id)") != nil {
                        config.set("hotkeys.\(entry.id)", config.defaultValue("hotkeys.\(entry.id)"))
                    }
                }
                .buttonStyle(ChromeButtonStyle())
            }
            ForEach(order.filter { groups[$0] != nil }, id: \.self) { group in
                SettingsGroup(L(group)) {
                    ForEach(groups[group] ?? [], id: \.id) { entry in row(entry) }
                }
            }
            if entries.isEmpty {
                Text(L("No hotkeys match “{filter}”", ["filter": filter])).foregroundStyle(chrome.textMuted.color)
            }
        }
        .sheet(item: $capturing) { entry in
            HotkeyCaptureSheet(entry: entry) { binding in
                capturing = nil
                guard let binding else { return }
                var list = HotkeyBinding.bindings(from: config.value("hotkeys.\(entry.id)"))
                list.append(binding)
                config.set("hotkeys.\(entry.id)", HotkeyBinding.configValue(for: list))
            }
            .chromeEnvironment()
        }
    }

    private func row(_ entry: HotkeyCatalog.Entry) -> some View {
        let config = AppServices.shared.config
        let bindings = HotkeyBinding.bindings(from: config.value("hotkeys.\(entry.id)"))
        let changed = config.user.value(at: "hotkeys.\(entry.id)") != nil
        return SettingsRow(entry.title) {
            HStack(spacing: 6) {
                if entry.id == "toggle-window" {
                    Text(L("global")).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).frame(height: 16)
                        .foregroundStyle(chrome.accent.color).background(Capsule().fill(chrome.accentFill.color))
                }
                ForEach(Array(bindings.enumerated()), id: \.offset) { index, b in
                    Keycap(b.symbolicDescription) {
                        var list = bindings
                        list.remove(at: index)
                        config.set("hotkeys.\(entry.id)", HotkeyBinding.configValue(for: list))
                    }
                }
                IconButton(symbol: "plus", help: L("Add a shortcut"), size: 22) { capturing = entry }
                if changed {
                    IconButton(symbol: "arrow.uturn.backward", help: L("Reset to the default"), size: 22) {
                        config.set("hotkeys.\(entry.id)", config.defaultValue("hotkeys.\(entry.id)"))
                    }
                }
            }
        }
    }
}

/// Records up to three keystrokes (a chord) for a binding and warns when another command
/// already uses it.
struct HotkeyCaptureSheet: View {
    let entry: HotkeyCatalog.Entry
    let done: (HotkeyBinding?) -> Void
    @State private var strokes: [Keystroke] = []
    @State private var monitor: Any?
    @Environment(\.chrome) private var chrome

    var body: some View {
        let binding = strokes.isEmpty ? nil : HotkeyBinding(strokes)
        let conflicts = binding.map { HotkeyCatalog.conflicts(with: $0, excluding: entry.id, config: AppServices.shared.config) } ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text(L("{name} · press a key combination", ["name": entry.title])).font(ChromeFont.headline)
            HStack(spacing: 6) {
                if strokes.isEmpty {
                    Text(L("Waiting for keys…")).foregroundStyle(chrome.textMuted.color)
                }
                ForEach(Array(strokes.enumerated()), id: \.offset) { _, s in
                    Text(s.symbolicDescription).font(.system(size: 20, weight: .medium)).padding(.horizontal, 10).frame(minHeight: 36)
                        .background(RoundedRectangle(cornerRadius: 7).fill(chrome.fillStrong.color))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chrome.accent.color, lineWidth: 1.5))
            if let first = conflicts.first {
                Label(conflicts.count > 1 ? L("Also used by “{name}” and {count} more", ["name": first.title, "count": conflicts.count - 1])
                                           : L("Also used by “{name}”", ["name": first.title]),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(chrome.warning.color)
            } else {
                Text(L("Press up to three keys in a row for a chord.")).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
            }
            HStack {
                Button(L("Clear")) { strokes = [] }.buttonStyle(ChromeButtonStyle()).disabled(strokes.isEmpty)
                Spacer()
                Button(L("Cancel")) { finish(nil) }.buttonStyle(ChromeButtonStyle())
                Button(L("Save")) { finish(binding) }.buttonStyle(ChromeButtonStyle(kind: .primary)).disabled(binding == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        HotkeyCapture.manager?.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if let stroke = KeyMapping.keystroke(for: event), strokes.count < 3 {
                if stroke.key == "Escape" && stroke.modifiers.isEmpty && strokes.isEmpty { // l10n-ignore: a key name
                    finish(nil)
                } else {
                    strokes.append(stroke)
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotkeyCapture.manager?.isSuspended = false
    }

    private func finish(_ binding: HotkeyBinding?) {
        stop()
        done(binding)
    }
}
#endif
