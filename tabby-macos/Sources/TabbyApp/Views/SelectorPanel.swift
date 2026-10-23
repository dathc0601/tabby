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
    /// Subdued (design C4: the Mac's built-in ports).
    var isDimmed = false
    var action: () -> Void
}

/// What the list shows when there is nothing to pick and nothing typed (design C4c).
struct SelectorEmptyState: Equatable {
    var icon: String
    var title: String
    var subtitle: String
}

/// One presentation of the selector.
@MainActor
struct SelectorConfig {
    var placeholder: String
    var items: [SelectorItem]
    var initialSelection = 0
    /// Rows made from the query (free input, quick connect).
    var dynamicItems: ((String) -> [SelectorItem])? = nil
    /// The query's rows lead the list (designs C4b, C5b) instead of following it.
    var dynamicItemsFirst = false
    /// nil: "Nothing here yet".
    var emptyState: SelectorEmptyState? = nil
    /// The footer's right-hand text; nil for none.
    var trailingHint: String? = SelectorPanel.profilesAndCommandsHint
}

/// The selector's rows: matches by score, each group kept together after its best match
/// (the first row is still the best match), under a header whenever the group changes.
enum SelectorList {
    static func rows(items: [SelectorItem], query: String, dynamicItems: ((String) -> [SelectorItem])?,
                     dynamicFirst: Bool) -> [SelectorItem] {
        let matches = query.isEmpty ? items : grouped(FuzzyMatcher.filter(items, query: query) { "\($0.group) \($0.title) \($0.subtitle)" })
        let typed = dynamicItems?(query) ?? []
        return dynamicFirst ? typed + matches : matches + typed
    }

    static func grouped(_ ranked: [SelectorItem]) -> [SelectorItem] {
        var order: [String] = []
        var byGroup: [String: [SelectorItem]] = [:]
        for item in ranked {
            if byGroup[item.group] == nil { order.append(item.group) }
            byGroup[item.group, default: []].append(item)
        }
        return order.flatMap { byGroup[$0] ?? [] }
    }

    /// The group header above row `index`, if one starts there.
    static func header(at index: Int, in rows: [SelectorItem]) -> String? {
        let group = rows[index].group
        guard !group.isEmpty, index == 0 || rows[index - 1].group != group else { return nil }
        return group
    }
}

/// The floating fuzzy-search list used for the profile selector, quick connect and the
/// command palette (Tabby's `SelectorModalComponent`), in the phase 2 design: 660 pt wide,
/// 44 pt below the tab bar, grouped rows, keyboard hints in the footer.
@MainActor
final class SelectorPanel: NSPanel {
    private static var current: SelectorPanel?
    static let size = CGSize(width: 660, height: 440)

    /// "⌘E profiles · ⌘⇧P commands", the footer of the general selectors.
    static var profilesAndCommandsHint: String? {
        guard let profiles = StartPageView.shortcut("profile-selector"), let commands = StartPageView.shortcut("command-selector") else { return nil }
        return "\(profiles) profiles · \(commands) commands"
    }

    static func present(over window: NSWindow?, placeholder: String, items: [SelectorItem],
                        initialSelection: Int = 0, dynamicItems: ((String) -> [SelectorItem])? = nil) {
        present(over: window, SelectorConfig(placeholder: placeholder, items: items, initialSelection: initialSelection,
                                             dynamicItems: dynamicItems))
    }

    static func present(over window: NSWindow?, _ config: SelectorConfig) {
        current?.close()
        let panel = SelectorPanel(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let view = SelectorView(config: config) { [weak panel] item in
            panel?.close()
            if let item { DispatchQueue.main.async { item.action() } }
        }
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.masksToBounds = true
        panel.contentView = host
        if let window {
            let f = window.frame
            let bar = CGFloat(AppServices.shared.theme.metrics.tabBar)
            panel.setFrameOrigin(CGPoint(x: f.midX - size.width / 2, y: f.maxY - bar - 44 - size.height))
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

/// Whether the row under the pointer takes the selection: only once the pointer has moved.
/// Rows that slide under a resting pointer while the list filters must not take it (found in
/// the M8 walk: Return then opened Quick connect instead of the profile). Tabby's selector
/// never selects on hover.
struct HoverSelection {
    private var last: CGPoint

    init(pointer: CGPoint) {
        last = pointer
    }

    mutating func shouldSelect(pointer: CGPoint) -> Bool {
        guard pointer != last else { return false }
        last = pointer
        return true
    }
}

struct SelectorView: View {
    let config: SelectorConfig
    let finish: (SelectorItem?) -> Void

    init(config: SelectorConfig, finish: @escaping (SelectorItem?) -> Void) {
        self.config = config
        self.finish = finish
    }

    init(placeholder: String, items: [SelectorItem], initialSelection: Int = 0,
         dynamicItems: ((String) -> [SelectorItem])?, finish: @escaping (SelectorItem?) -> Void) {
        self.init(config: SelectorConfig(placeholder: placeholder, items: items, initialSelection: initialSelection,
                                         dynamicItems: dynamicItems), finish: finish)
    }

    var body: some View {
        SelectorContent(config: config, finish: finish).chromeEnvironment()
    }
}

private struct SelectorContent: View {
    let config: SelectorConfig
    let finish: (SelectorItem?) -> Void
    private var placeholder: String { config.placeholder }
    private var items: [SelectorItem] { config.items }
    @State private var query = ""
    @State private var selection = 0
    @State private var hover = HoverSelection(pointer: NSEvent.mouseLocation)
    @FocusState private var focused: Bool
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics

    private var filtered: [SelectorItem] {
        SelectorList.rows(items: items, query: query, dynamicItems: config.dynamicItems, dynamicFirst: config.dynamicItemsFirst)
    }

    var body: some View {
        let list = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17)).foregroundStyle(chrome.textMuted.color)
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onChange(of: query) { selection = 0 }
                    .onSubmit { finish(list.indices.contains(selection) ? list[selection] : nil) }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onExitCommand { finish(nil) }
                Keycap("esc")
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            if list.isEmpty {
                VStack(spacing: 6) {
                    let empty = query.isEmpty ? config.emptyState : nil
                    Image(systemName: empty?.icon ?? "magnifyingglass").font(.system(size: 28)).foregroundStyle(chrome.textFaint.color)
                    Text(empty?.title ?? (query.isEmpty ? "Nothing here yet" : "No matches for “\(query)”"))
                        .font(ChromeFont.bodyEmphasised).foregroundStyle(chrome.text.color)
                    if let subtitle = empty?.subtitle {
                        Text(subtitle).font(ChromeFont.caption)
                    }
                }
                .foregroundStyle(chrome.textMuted.color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                if let header = SelectorList.header(at: index, in: list) {
                                    // The designs' header: sentence case, 11 pt semibold, faint.
                                    Text(header).font(ChromeFont.groupHeader).foregroundStyle(chrome.textFaint.color)
                                        .padding(.horizontal, 10).padding(.top, index == 0 ? 4 : 10).padding(.bottom, 3)
                                } else if index > 0 && item.group.isEmpty && !list[index - 1].group.isEmpty {
                                    Color.clear.frame(height: 6)
                                }
                                SelectorRow(item: item, isSelected: index == selection)
                                    .id(item.id)
                                    .onTapGesture { finish(item) }
                                    .onHover { if $0, hover.shouldSelect(pointer: NSEvent.mouseLocation) { selection = index } }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selection) {
                        if list.indices.contains(selection) { proxy.scrollTo(list[selection].id) }
                    }
                    .onAppear {
                        // The preselected row (115200 in the baud-rate list) opens in view.
                        guard list.indices.contains(config.initialSelection), config.initialSelection > 0 else { return }
                        let id = list[config.initialSelection].id
                        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            HStack(spacing: 14) {
                hint("↑↓", "select")
                hint("↩", "open")
                hint("esc", "close")
                Spacer()
                if let trailing = config.trailingHint {
                    Text(trailing).foregroundStyle(chrome.textFaint.color)
                }
            }
            .font(ChromeFont.caption)
            .foregroundStyle(chrome.textMuted.color)
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
        .frame(width: SelectorPanel.size.width, height: SelectorPanel.size.height)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .onAppear {
            focused = true
            if items.indices.contains(config.initialSelection) { selection = config.initialSelection }
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Keycap(key)
            Text(label)
        }
    }
}

struct SelectorRow: View {
    let item: SelectorItem
    let isSelected: Bool
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics

    var body: some View {
        let tint = item.color.flatMap(RGBColor.init(hex:))
        let fg = isSelected ? chrome.onAccent : item.isDimmed ? chrome.textMuted : chrome.text
        let muted = isSelected ? chrome.onAccent.withAlpha(0.72) : item.isDimmed ? chrome.textFaint : chrome.textMuted
        let subtitle = item.subtitle
        HStack(spacing: 10) {
            Image(systemName: item.icon ?? "terminal")
                .font(.system(size: 14))
                .frame(width: 20)
                .foregroundStyle((isSelected ? chrome.onAccent : (tint ?? (item.isDimmed ? chrome.textFaint : chrome.textMuted))).color)
            Text(item.title).font(ChromeFont.bodyEmphasised).foregroundStyle(fg.color).lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle).font(ChromeFont.caption).foregroundStyle(muted.color).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let tint { StatusDot(color: isSelected ? chrome.onAccent : tint, size: 7) }
            if let shortcut = item.shortcut {
                Text(shortcut).font(ChromeFont.caption).foregroundStyle(muted.color)
            }
            if isSelected {
                Text("↩ open").font(.system(size: 11, weight: .medium)).padding(.horizontal, 6).frame(height: 18)
                    .foregroundStyle(chrome.onAccent.color)
                    .background(Capsule().fill(chrome.onAccent.withAlpha(0.18).color))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: CGFloat(metrics.selectorRow))
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? chrome.accent.color : .clear))
        .contentShape(Rectangle())
    }
}
#endif
