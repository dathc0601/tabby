#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// One row of the selector (Tabby's `SelectorOption`).
struct SelectorItem: Identifiable {
    let id: String
    var title: String
    var group: String = ""
    var subtitle: String = ""
    var icon: String? = nil
    var color: String? = nil
    var shortcut: String? = nil
    var action: () -> Void
}

/// The floating fuzzy-search list used for the profile selector, quick connect and the
/// command palette (Tabby's `SelectorModalComponent`).
@MainActor
final class SelectorPanel: NSPanel {
    private static var current: SelectorPanel?

    static func present(over window: NSWindow?, placeholder: String, items: [SelectorItem],
                        dynamicItems: ((String) -> [SelectorItem])? = nil) {
        current?.close()
        let panel = SelectorPanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 420),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let view = SelectorView(placeholder: placeholder, items: items, dynamicItems: dynamicItems) { [weak panel] item in
            panel?.close()
            if let item { DispatchQueue.main.async { item.action() } }
        }
        panel.contentView = NSHostingView(rootView: view)
        if let window {
            let f = window.frame
            panel.setFrameOrigin(CGPoint(x: f.midX - 280, y: f.maxY - 420 - 80))
        } else {
            panel.center()
        }
        current = panel
        panel.makeKeyAndOrderFront(nil)
    }

    override var canBecomeKey: Bool { true }

    private var isClosing = false

    override func resignKey() {
        super.resignKey()
        if !isClosing { close() }
    }

    override func close() {
        guard !isClosing else { return }
        isClosing = true
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

struct SelectorView: View {
    let placeholder: String
    let items: [SelectorItem]
    let dynamicItems: ((String) -> [SelectorItem])?
    let finish: (SelectorItem?) -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var filtered: [SelectorItem] {
        let base = FuzzyMatcher.filter(items, query: query) { "\($0.group) \($0.title) \($0.subtitle)" }
        return base + (dynamicItems?(query) ?? [])
    }

    var body: some View {
        let chrome = AppServices.shared.theme.chrome
        let list = filtered
        VStack(spacing: 0) {
            TextField(placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onChange(of: query) { selection = 0 }
                .onSubmit { finish(list.indices.contains(selection) ? list[selection] : nil) }
                .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                .onExitCommand { finish(nil) }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                            SelectorRow(item: item, isSelected: index == selection)
                                .id(item.id)
                                .onTapGesture { finish(item) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) {
                    if list.indices.contains(selection) { proxy.scrollTo(list[selection].id) }
                }
            }
            if list.isEmpty {
                Text("No matches").foregroundStyle(chrome.textMuted.color).padding()
            }
            HStack(spacing: 14) {
                Label("open", systemImage: "return")
                Label("close", systemImage: "escape")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(chrome.textMuted.color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 560, height: 420)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .onAppear { focused = true }
    }
}

struct SelectorRow: View {
    let item: SelectorItem
    let isSelected: Bool

    var body: some View {
        let chrome = AppServices.shared.theme.chrome
        HStack(spacing: 10) {
            Image(systemName: item.icon ?? "terminal")
                .frame(width: 18)
                .foregroundStyle(item.color.flatMap(RGBColor.init(hex:))?.color ?? chrome.textMuted.color)
            if !item.group.isEmpty {
                Text(item.group).foregroundStyle(chrome.textMuted.color)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(chrome.textFaint.color)
            }
            Text(item.title).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).foregroundStyle(chrome.textMuted.color).lineLimit(1)
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut).font(.callout).foregroundStyle(chrome.textMuted.color)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? chrome.accent.color.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}
#endif
