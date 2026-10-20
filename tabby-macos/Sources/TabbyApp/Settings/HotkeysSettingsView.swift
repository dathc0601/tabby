#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// Lets the capture sheet pause the global hotkey monitor.
@MainActor
enum HotkeyCapture {
    static var manager: HotkeyManager?
}

/// Filterable list of hotkeys with a capture sheet (Tabby's `HotkeySettingsTabComponent`).
struct HotkeysSettingsView: View {
    @State private var filter = ""
    @State private var capturing: HotkeyCatalog.Entry?

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        let entries = FuzzyMatcher.filter(HotkeyCatalog.entries, query: filter) { "\($0.group) \($0.name) \($0.id)" }
        VStack(alignment: .leading) {
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            List(entries, id: \.id) { entry in
                let bindings = HotkeyBinding.bindings(from: services.config.value("hotkeys.\(entry.id)"))
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.name)
                        Text("\(entry.group) · \(entry.id)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ForEach(Array(bindings.enumerated()), id: \.offset) { index, b in
                        HStack(spacing: 2) {
                            Text(b.symbolicDescription).font(.system(.body, design: .rounded))
                            Button {
                                var list = bindings
                                list.remove(at: index)
                                services.config.set("hotkeys.\(entry.id)", HotkeyBinding.configValue(for: list))
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Button { capturing = entry } label: { Image(systemName: "plus") }.buttonStyle(.borderless)
                    Button("Reset") {
                        services.config.set("hotkeys.\(entry.id)", services.config.defaultValue("hotkeys.\(entry.id)"))
                    }
                    .buttonStyle(.borderless)
                    .disabled(services.config.user.value(at: "hotkeys.\(entry.id)") == nil)
                }
            }
        }
        .padding()
        .sheet(item: $capturing) { entry in
            HotkeyCaptureSheet(entry: entry) { binding in
                capturing = nil
                guard let binding else { return }
                var list = HotkeyBinding.bindings(from: services.config.value("hotkeys.\(entry.id)"))
                list.append(binding)
                services.config.set("hotkeys.\(entry.id)", HotkeyBinding.configValue(for: list))
            }
        }
    }
}


/// Records up to three keystrokes (a chord) for a binding.
struct HotkeyCaptureSheet: View {
    let entry: HotkeyCatalog.Entry
    let done: (HotkeyBinding?) -> Void
    @State private var strokes: [Keystroke] = []
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 16) {
            Text("Press the shortcut for “\(entry.name)”").font(.headline)
            Text(strokes.isEmpty ? "…" : HotkeyBinding(strokes).symbolicDescription)
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .frame(minWidth: 240, minHeight: 50)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text("Press up to three keys in a row for a chord.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { finish(nil) }
                Button("Clear") { strokes = [] }
                Button("Save") { finish(strokes.isEmpty ? nil : HotkeyBinding(strokes)) }
                    .disabled(strokes.isEmpty)
            }
        }
        .padding(24)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        HotkeyCapture.manager?.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if let stroke = KeyMapping.keystroke(for: event), strokes.count < 3 {
                if stroke.key == "Escape" && stroke.modifiers.isEmpty && strokes.isEmpty {
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
