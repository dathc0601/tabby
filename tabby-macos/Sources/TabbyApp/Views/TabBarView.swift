#if canImport(AppKit)
import SwiftUI
import AppKit
import TabbyCore
import TabbyTerminal

/// Everything the tab bar can ask the window to do.
@MainActor
struct TabBarActions {
    var select: (TabModel) -> Void
    var close: (TabModel) -> Void
    var newTab: () -> Void
    var showProfiles: () -> Void
    var showSettings: () -> Void
    var command: (String, TabModel?) -> Void
    var move: (UUID, Int) -> Void
    var setColor: (TabModel, String?) -> Void
}

enum TabBarPlacement {
    case top, bottom, left, right
    var isVertical: Bool { self == .left || self == .right }
}

/// Tabby's tab strip (`appRoot.component.pug` + `tabHeader.component.pug`) in the phase 2
/// design: 38 pt bar × spaciness in `surfaceChrome`, 28 pt rounded tabs, a "+N" overflow menu,
/// and the toolbar on the trailing side (on the column footer when the bar is vertical).
struct TabBarView: View {
    let model: WindowModel
    let actions: TabBarActions
    let placement: TabBarPlacement
    /// Space reserved for the traffic lights.
    let leadingInset: CGFloat

    var body: some View {
        Group {
            if placement.isVertical {
                VerticalTabBar(model: model, actions: actions, placement: placement, topInset: leadingInset)
            } else {
                HorizontalTabBar(model: model, actions: actions, leadingInset: leadingInset)
            }
        }
        .chromeEnvironment()
    }
}

private struct TabFramesKey: PreferenceKey {
    static let defaultValue: [UUID: ClosedRange<Double>] = [:]
    static func reduce(value: inout [UUID: ClosedRange<Double>], nextValue: () -> [UUID: ClosedRange<Double>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct HorizontalTabBar: View {
    let model: WindowModel
    let actions: TabBarActions
    let leadingInset: CGFloat
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics
    @State private var frames: [UUID: ClosedRange<Double>] = [:]
    @State private var dropTarget: UUID?

    /// The "+" button, the minimum drag area and the trailing toolbar.
    static let newTabWidth: CGFloat = 32
    static let dragMinimum: CGFloat = 24
    static let toolbarWidth: CGFloat = 3 * 28 + 2 * 2 + 8
    /// With the transfers button (shown while there are transfers).
    static func toolbarWidth(showsTransfers: Bool) -> CGFloat {
        showsTransfers ? toolbarWidth + 28 + 2 : toolbarWidth
    }

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        let flex = services.config.bool("appearance.flexTabs")
        let pinned = model.tabs.filter(\.isPinned).count
        let showsTransfers = !TransferCenter.shared.transfers.isEmpty
        GeometryReader { geo in
            let fixedParts = leadingInset + Self.newTabWidth + Self.dragMinimum + Self.toolbarWidth(showsTransfers: showsTransfers)
            let layout = TabStripLayout(available: Double(geo.size.width - fixedParts), pinned: pinned,
                                        regular: model.tabs.count - pinned, flex: flex)
            HStack(spacing: 0) {
                Color.clear.frame(width: leadingInset)
                strip(layout)
                    .frame(width: CGFloat(layout.stripWidth))
                if layout.overflows { overflowMenu(layout) }
                IconButton(symbol: "plus", help: "New tab", action: actions.newTab)
                    .frame(width: Self.newTabWidth)
                WindowDragArea().frame(minWidth: Self.dragMinimum, maxWidth: .infinity)
                HStack(spacing: 2) {
                    TransfersToolbarButton()
                    IconButton(symbol: "rectangle.stack", help: "Profiles & connections", action: actions.showProfiles)
                    IconButton(symbol: "gearshape", help: "Settings", action: actions.showSettings)
                    AccountToolbarButton(openSettings: { WindowManager.shared.openSettings(section: .account) })
                }
                .padding(.trailing, 8)
            }
            .frame(height: geo.size.height)
        }
        .frame(height: CGFloat(metrics.tabBar))
        .background(chrome.chromeBackground.color)
        .overlay(alignment: .bottom) { Rectangle().fill(chrome.separator.color).frame(height: 1) }
    }

    private func strip(_ layout: TabStripLayout) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CGFloat(TabStripLayout.gap)) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabHeaderView(tab: tab, index: index, isActive: tab === model.activeTab,
                                      width: CGFloat(tab.isPinned ? layout.pinnedWidth : layout.regularWidth),
                                      vertical: false, actions: actions)
                            .id(tab.id)
                            .background(GeometryReader { g in
                                let f = g.frame(in: .named("tab-strip"))
                                Color.clear.preference(key: TabFramesKey.self, value: [tab.id: Double(f.minX)...Double(max(f.minX, f.maxX))])
                            })
                            .modifier(TabDragModifier(tab: tab, index: index, vertical: false, actions: actions, dropTarget: $dropTarget))
                    }
                }
                .frame(height: CGFloat(metrics.tabBar))
            }
            .scrollDisabled(!layout.overflows)
            .coordinateSpace(name: "tab-strip")
            .onPreferenceChange(TabFramesKey.self) { frames = $0 }
            .onChange(of: model.activeTabID) { _, id in
                guard let id, layout.overflows else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            // The scroll offset outlives a change of the strip's size (a narrower window, a
            // window laid out again at launch): keep the active tab whole then too.
            .onChange(of: layout) { _, _ in scrollToActiveTab(proxy) }
            .onAppear { scrollToActiveTab(proxy) }
        }
    }

    /// From `onChange`/`onAppear` only: SwiftUI traps a proxy used during a view update (a
    /// deferred `Task` can land in one).
    private func scrollToActiveTab(_ proxy: ScrollViewProxy) {
        guard let id = model.activeTabID else { return }
        proxy.scrollTo(id)
    }

    private func overflowMenu(_ layout: TabStripLayout) -> some View {
        let ordered = model.tabs.map { frames[$0.id] ?? 0...0 }
        let hidden = TabStripLayout.hiddenIndices(frames: ordered, viewport: 0...layout.stripWidth)
            .filter { $0 < model.tabs.count }
        return Menu {
            ForEach(hidden, id: \.self) { i in
                let tab = model.tabs[i]
                Button("\(i + 1)  \(tab.title)") { actions.select(tab) }
            }
        } label: {
            // One Text: a menu label with an Image puts the image first.
            (Text("+\(hidden.count) ") + Text(Image(systemName: "chevron.down")).font(.system(size: 9, weight: .semibold)))
                .font(ChromeFont.caption.monospacedDigit())
                .foregroundStyle(chrome.textMuted.color)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: CGFloat(TabStripLayout.overflowButton))
        .opacity(hidden.isEmpty ? 0 : 1)
        .help("Tabs out of view")
    }
}

struct VerticalTabBar: View {
    let model: WindowModel
    let actions: TabBarActions
    let placement: TabBarPlacement
    let topInset: CGFloat
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics
    @State private var dropTarget: UUID?

    var body: some View {
        let _ = AppServices.shared.configRevision
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: CGFloat(TabStripLayout.gap)) {
                        ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabHeaderView(tab: tab, index: index, isActive: tab === model.activeTab, width: nil,
                                          vertical: true, actions: actions)
                                .id(tab.id)
                                .modifier(TabDragModifier(tab: tab, index: index, vertical: true, actions: actions, dropTarget: $dropTarget))
                        }
                        NewTabRow(action: actions.newTab)
                    }
                    .padding(6)
                }
                .onChange(of: model.activeTabID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            HStack(spacing: 2) {
                IconButton(symbol: "rectangle.stack", help: "Profiles & connections", action: actions.showProfiles)
                IconButton(symbol: "gearshape", help: "Settings", action: actions.showSettings)
                TransfersToolbarButton()
                Spacer(minLength: 0)
                AccountToolbarButton(openSettings: { WindowManager.shared.openSettings(section: .account) })
            }
            .padding(6)
        }
        .frame(width: 200)
        .background(chrome.chromeBackground.color)
        .overlay(alignment: placement == .left ? .trailing : .leading) {
            Rectangle().fill(chrome.separator.color).frame(width: 1)
        }
    }
}

/// "New tab ⌘T" row at the end of a vertical tab bar.
private struct NewTabRow: View {
    let action: () -> Void
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 12))
                Text("New tab").font(ChromeFont.body)
                Spacer(minLength: 0)
                if let key = StartPageView.shortcut("new-tab") {
                    Text(key).font(ChromeFont.caption).foregroundStyle(chrome.textFaint.color)
                }
            }
            .foregroundStyle(chrome.textMuted.color)
            .padding(.leading, 9).padding(.trailing, 8)
            .frame(height: CGFloat(metrics.space(30)))
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? chrome.fill.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Drag to reorder: the tab under the pointer shows an accent slot on the side the dragged
/// tab will land.
private struct TabDragModifier: ViewModifier {
    let tab: TabModel
    let index: Int
    let vertical: Bool
    let actions: TabBarActions
    @Binding var dropTarget: UUID?
    @Environment(\.chrome) private var chrome

    func body(content: Content) -> some View {
        content
            .onTapGesture { actions.select(tab) }
            .draggable(tab.id.uuidString) {
                Text(tab.title).font(ChromeFont.bodyEmphasised)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(chrome.surface.color))
                    .foregroundStyle(chrome.text.color)
            }
            .dropDestination(for: String.self) { items, _ in
                dropTarget = nil
                guard let first = items.first, let id = UUID(uuidString: first) else { return false }
                actions.move(id, index)
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = tab.id } else if dropTarget == tab.id { dropTarget = nil }
            }
            .overlay(alignment: vertical ? .top : .leading) {
                if dropTarget == tab.id {
                    RoundedRectangle(cornerRadius: 1).fill(chrome.accent.color)
                        .frame(width: vertical ? nil : 2, height: vertical ? 2 : nil)
                        .offset(x: vertical ? 0 : -2, y: vertical ? -2 : 0)
                }
            }
            .contextMenu { TabContextMenu(tab: tab, actions: actions) }
    }
}

struct TabHeaderView: View {
    let tab: TabModel
    let index: Int
    let isActive: Bool
    /// Fixed width in a horizontal strip; nil fills the column of a vertical bar.
    let width: CGFloat?
    let vertical: Bool
    let actions: TabBarActions
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    var body: some View {
        let services = AppServices.shared
        let hideIndex = services.config.bool("terminal.hideTabIndex")
        let hideClose = services.config.bool("terminal.hideCloseButton")
        let showIcon = services.config.bool("terminal.showTabProfileIcon")
        let userColor = tab.color.flatMap(RGBColor.init(hex:))
        let profileColor = tab.focusedPane?.profile.color.flatMap(RGBColor.init(hex:))
        let compact = !vertical && tab.isPinned
        HStack(spacing: 6) {
            if !hideIndex {
                Text("\(index + 1)").font(ChromeFont.tabIndex).foregroundStyle(chrome.textFaint.color).fixedSize()
            }
            if let content = tab.content {
                Image(systemName: content.symbol).font(.system(size: 12)).foregroundStyle(chrome.textMuted.color)
            } else if showIcon, let icon = tab.icon {
                Image(systemName: ProfileIcons.symbol(for: icon))
                    .font(.system(size: 12))
                    .foregroundStyle((Self.connectionTint(tab.focusedPane?.connectionState, chrome) ?? profileColor ?? userColor ?? chrome.textMuted).color)
            }
            Text(tab.title)
                .font(isActive ? ChromeFont.bodyEmphasised : ChromeFont.body)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle((isActive || hovering ? chrome.text : chrome.textMuted).color)
            Spacer(minLength: 0)
            if let p = tab.progress, !compact {
                Text("\(Int(p.rounded()))%").font(ChromeFont.tabIndex).foregroundStyle(chrome.accent.color).fixedSize()
            }
            if tab.hasActivity && !isActive {
                StatusDot(color: chrome.accent)
            }
            if tab.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(chrome.textMuted.color)
                    .help("Pinned")
            } else {
                if hovering && !compact {
                    Menu {
                        TabContextMenu(tab: tab, actions: actions)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18, height: 18)
                    .help("Tab options")
                }
                if !hideClose {
                    Button { actions.close(tab) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? chrome.fillStrong.color : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(chrome.textMuted.color)
                    .opacity(hovering || isActive ? 1 : 0)
                    .help("Close tab")
                }
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(width: width, height: CGFloat(vertical ? metrics.space(30) : metrics.tab))
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background {
            // Progress fills the tab from the leading edge (the design's "fill + %").
            if let p = tab.progress {
                GeometryReader { g in
                    Rectangle().fill(chrome.accentFill.color).frame(width: g.size.width * CGFloat(min(max(p, 0), 100) / 100))
                }
            }
        }
        .background(isActive ? chrome.activeTab.color : (hovering ? chrome.fill.color : .clear))
        .overlay(alignment: vertical ? .leading : .bottom) {
            if let userColor {
                Rectangle().fill(userColor.color)
                    .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isActive ? chrome.border.color : .clear, lineWidth: 0.5))
        .shadow(color: .black.opacity(isActive ? 0.16 : 0), radius: 1, y: 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

extension TabHeaderView {
    /// SSH tabs tint their icon with the connection state (the design's status chip colours).
    static func connectionTint(_ state: TerminalPane.ConnectionState?, _ chrome: ChromeTheme) -> RGBColor? {
        switch state {
        case .connecting?, .reconnecting?: return chrome.warning
        case .disconnected?: return chrome.danger
        default: return nil
        }
    }
}

struct TabContextMenu: View {
    let tab: TabModel
    let actions: TabBarActions

    var body: some View {
        Button("Close Tab") { actions.close(tab) }
        Button("Close Other Tabs") { actions.command("close-other-tabs", tab) }
        Button("Close Tabs to the Left") { actions.command("close-tabs-left", tab) }
        Button("Close Tabs to the Right") { actions.command("close-tabs-right", tab) }
        Divider()
        if tab.content == nil {
            Button("Rename Tab…") { actions.command("rename-tab", tab) }
            Button("Duplicate Tab") { actions.command("duplicate-tab", tab) }
        }
        Button(tab.isPinned ? "Unpin Tab" : "Pin Tab") { actions.command("pin-tab", tab) }
        Menu("Colour") {
            Button { actions.setColor(tab, nil) } label: {
                if tab.color == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            Divider()
            ForEach(TabColors.current()) { c in
                Button { actions.setColor(tab, c.hex) } label: {
                    Label { Text(c.name) } icon: { Image(nsImage: TabColors.swatch(c.hex, checked: tab.color?.lowercased() == c.hex)) }
                }
            }
        }
        if tab.content == nil {
            Divider()
            Menu("Split") {
                Button("Split Up") { actions.command("split-top", tab) }
                Button("Split Right") { actions.command("split-right", tab) }
                Button("Split Down") { actions.command("split-bottom", tab) }
                Button("Split Left") { actions.command("split-left", tab) }
            }
            Button("Save Layout as Profile…") { actions.command("save-layout-as-profile", tab) }
            Button("Switch Profile…") { actions.command("switch-profile", tab) }
        }
    }
}

/// Tab colours: the active scheme's six ANSI colours (the design's Colour submenu), stored as
/// hex like Tabby's tab colours.
struct TabColors: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    @MainActor
    static func current() -> [TabColors] {
        let p = AppServices.shared.theme.scheme.paletteRGB
        return [("Red", 1), ("Yellow", 3), ("Green", 2), ("Cyan", 6), ("Blue", 4), ("Magenta", 5)].map {
            TabColors(name: $0.0, hex: p[$0.1].hex)
        }
    }

    /// A round swatch for menus (not a template image, so it keeps its colour).
    static func swatch(_ hex: String, checked: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            (RGBColor(hex: hex) ?? .black).nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            if checked {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
                ring.lineWidth = 2
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Maps Tabby's Font Awesome icon names to SF Symbols, falling back to a terminal glyph.
enum ProfileIcons {
    static func symbol(for icon: String) -> String {
        let name = icon.replacingOccurrences(of: "fas fa-", with: "").replacingOccurrences(of: "fab fa-", with: "")
        let map = ["terminal": "terminal", "network": "network", "server": "server.rack", "desktop": "desktopcomputer",
                   "laptop": "laptopcomputer", "globe": "globe", "bolt": "bolt", "cloud": "cloud", "database": "cylinder",
                   "linux": "terminal", "apple": "apple.logo", "docker": "shippingbox", "code": "chevron.left.forwardslash.chevron.right",
                   "microchip": "memorychip", "network-wired": "network"]
        return map[name] ?? "terminal"
    }

    /// Icons the profile editor offers (Tabby's Font Awesome names, shown as SF Symbols).
    static let choices = ["terminal", "server", "desktop", "laptop", "globe", "cloud", "database", "bolt", "code", "docker", "apple", "linux", "network"]
}

/// Empty space in the tab bar that drags the window (and zooms on double click).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
