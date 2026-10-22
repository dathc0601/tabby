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

/// Tabby's tab strip (`appRoot.component.pug` + `tabHeader.component.pug`).
/// Pure presentation over `WindowModel`; replace freely when redesigning.
struct TabBarView: View {
    let model: WindowModel
    let actions: TabBarActions
    let placement: TabBarPlacement
    /// Space reserved for the traffic lights.
    let leadingInset: CGFloat

    var body: some View {
        let services = AppServices.shared
        let chrome = services.theme.chrome
        let height = 38 * services.theme.spaciness
        let flex = services.config.bool("appearance.flexTabs")
        let _ = services.configRevision
        Group {
            if placement.isVertical {
                VStack(spacing: 0) {
                    Color.clear.frame(height: leadingInset)
                    ScrollView(.vertical) {
                        VStack(spacing: 2) { tabs(chrome: chrome, height: height, flex: true) }
                    }
                    Spacer(minLength: 0)
                    HStack { buttons(chrome: chrome) }.padding(8)
                }
                .frame(width: 200)
            } else {
                HStack(spacing: 0) {
                    Color.clear.frame(width: leadingInset)
                    // Tabs claim the width before the drag area and shrink when it runs out, as
                    // Tabby's `.tabs { flex: 0 1 auto }` of 200 px headers with `min-width: 0`.
                    HStack(spacing: 0) { tabs(chrome: chrome, height: height, flex: flex) }
                        .layoutPriority(1)
                    Button(action: actions.newTab) {
                        Image(systemName: "plus").frame(width: 32, height: height)
                    }
                    .buttonStyle(.plain)
                    .help("New tab")
                    WindowDragArea().frame(minWidth: 24, maxWidth: .infinity)
                    buttons(chrome: chrome).padding(.trailing, 8)
                }
                .frame(height: height)
            }
        }
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceSunken.color.opacity(services.theme.vibrancy ? 0.5 : 1))
    }

    @ViewBuilder
    private func tabs(chrome: ChromeTheme, height: CGFloat, flex: Bool) -> some View {
        ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
            TabHeaderView(tab: tab, index: index, isActive: tab === model.activeTab,
                          height: height, vertical: placement.isVertical, flex: flex, actions: actions)
                .onTapGesture { actions.select(tab) }
                .draggable(tab.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let first = items.first, let id = UUID(uuidString: first) else { return false }
                    actions.move(id, index)
                    return true
                }
                .contextMenu { TabContextMenu(tab: tab, actions: actions) }
        }
    }

    @ViewBuilder
    private func buttons(chrome: ChromeTheme) -> some View {
        Button(action: actions.showProfiles) { Image(systemName: "rectangle.stack") }
            .help("Profiles & connections")
        Button(action: actions.showSettings) { Image(systemName: "gearshape") }
            .help("Settings")
    }
}

struct TabHeaderView: View {
    let tab: TabModel
    let index: Int
    let isActive: Bool
    let height: CGFloat
    let vertical: Bool
    let flex: Bool
    let actions: TabBarActions
    @State private var hovering = false

    var body: some View {
        let services = AppServices.shared
        let chrome = services.theme.chrome
        let hideIndex = services.config.bool("terminal.hideTabIndex")
        let hideClose = services.config.bool("terminal.hideCloseButton")
        let showIcon = services.config.bool("terminal.showTabProfileIcon")
        ZStack(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                if !hideIndex {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(chrome.textMuted.color)
                        .fixedSize()
                }
                if showIcon, let icon = tab.icon {
                    Image(systemName: ProfileIcons.symbol(for: icon)).font(.caption)
                }
                if tab.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(chrome.textMuted.color)
                }
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isActive ? chrome.text.color : chrome.textMuted.color)
                Spacer(minLength: 0)
                if tab.hasActivity && !isActive {
                    Circle().fill(chrome.accent.color).frame(width: 6, height: 6)
                }
                if !hideClose && !tab.isPinned {
                    Button { actions.close(tab) } label: { Image(systemName: "xmark").font(.caption2.weight(.semibold)) }
                        .buttonStyle(.plain)
                        .opacity(hovering || isActive ? 1 : 0)
                        .help("Close tab")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: height)
            if let p = tab.progress {
                GeometryReader { g in
                    Rectangle().fill(chrome.accent.color.opacity(0.35))
                        .frame(width: g.size.width * CGFloat(p / 100), height: 2)
                }
                .frame(height: 2)
            }
            // Tabby's `.colorbar` runs along the bottom; the top line marks the active tab.
            if let color = tab.color.flatMap(RGBColor.init(hex:)) {
                Rectangle().fill(color.color).frame(height: 3)
            }
        }
        .frame(minWidth: 0, maxWidth: vertical || flex ? .infinity : 200)
        .background(isActive ? chrome.surface.color : (hovering ? chrome.surfaceRaised.color.opacity(0.5) : .clear))
        .overlay(alignment: vertical ? .leading : .top) {
            if isActive {
                Rectangle().fill(chrome.accent.color)
                    .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
            }
        }
        // Narrow tabs cut their content off at the edge, as Tabby's `overflow: hidden`.
        .clipped()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tab.title)
    }
}

struct TabContextMenu: View {
    let tab: TabModel
    let actions: TabBarActions

    var body: some View {
        Button("Close") { actions.close(tab) }
        Button("Close other tabs") { actions.command("close-other-tabs", tab) }
        Button("Close tabs to the left") { actions.command("close-tabs-left", tab) }
        Button("Close tabs to the right") { actions.command("close-tabs-right", tab) }
        Divider()
        Button("Rename…") { actions.command("rename-tab", tab) }
        Button("Duplicate") { actions.command("duplicate-tab", tab) }
        Button(tab.isPinned ? "Unpin" : "Pin") { actions.command("pin-tab", tab) }
        Menu("Color") {
            Button("No color") { actions.setColor(tab, nil) }
            ForEach(TabColors.all) { c in
                Button(c.name) { actions.setColor(tab, c.hex) }
            }
        }
        Divider()
        Button("Split right") { actions.command("split-right", tab) }
        Button("Split down") { actions.command("split-bottom", tab) }
        Button("Split left") { actions.command("split-left", tab) }
        Button("Split up") { actions.command("split-top", tab) }
        Divider()
        Button("Save layout as profile") { actions.command("save-layout-as-profile", tab) }
    }
}

/// Tab colours offered in the context menu (from `tabby-core/src/tabContextMenu.ts`).
struct TabColors: Identifiable {
    let name: String
    let hex: String
    var id: String { hex }

    static let all: [TabColors] = [
        TabColors(name: "Blue", hex: "#0275d8"), TabColors(name: "Green", hex: "#5cb85c"),
        TabColors(name: "Orange", hex: "#f0ad4e"), TabColors(name: "Purple", hex: "#613d7c"),
        TabColors(name: "Red", hex: "#d9534f"), TabColors(name: "Yellow", hex: "#ffd500"),
    ]
}

/// Maps Tabby's Font Awesome icon names to SF Symbols, falling back to a terminal glyph.
enum ProfileIcons {
    static func symbol(for icon: String) -> String {
        let name = icon.replacingOccurrences(of: "fas fa-", with: "").replacingOccurrences(of: "fab fa-", with: "")
        let map = ["terminal": "terminal", "network": "network", "server": "server.rack", "desktop": "desktopcomputer",
                   "laptop": "laptopcomputer", "globe": "globe", "bolt": "bolt", "cloud": "cloud", "database": "cylinder",
                   "linux": "terminal", "apple": "apple.logo", "docker": "shippingbox", "code": "chevron.left.forwardslash.chevron.right"]
        return map[name] ?? "terminal"
    }
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
