#if canImport(AppKit)
import SwiftUI
import AppKit
import TabbyCore

/// Shown when a window has no tabs (Tabby's `StartPageComponent`, in the phase 2 design): the
/// logo tile, a card of actions and recent profiles (↑ ↓ select, ↩ opens, ⌘1–⌘3 open the
/// recents), and a footer with links and the version.
struct StartPageView: View {
    var newTab: () -> Void
    var showProfiles: () -> Void
    var showSettings: () -> Void
    var openProfile: (Profile) -> Void

    var body: some View {
        StartPageContent(newTab: newTab, showProfiles: showProfiles, showSettings: showSettings, openProfile: openProfile)
            .chromeEnvironment()
    }

    static func shortcut(_ id: String) -> String? {
        HotkeyBinding.bindings(from: AppServices.shared.config.value("hotkeys.\(id)")).first?.symbolicDescription
    }

    /// The profiles the start page lists under Recent (`terminal.showRecentProfiles`, at most 3
    /// so ⌘1–⌘3 reach all of them).
    @MainActor
    static func recentProfiles() -> [Profile] {
        let services = AppServices.shared
        return Array(services.profiles.recents.load().prefix(min(3, services.config.int("terminal.showRecentProfiles") ?? 3)))
    }

    static let repositoryURL = URL(string: "https://github.com/dathc0601/tabby")!
}

private struct StartPageContent: View {
    var newTab: () -> Void
    var showProfiles: () -> Void
    var showSettings: () -> Void
    var openProfile: (Profile) -> Void
    @Environment(\.chrome) private var chrome
    @State private var selection = 0
    @FocusState private var focused: Bool

    private struct Row {
        let icon: String
        let tint: RGBColor?
        let title: String
        let subtitle: String?
        let shortcut: String?
        let action: () -> Void
    }

    private func rows(recents: [Profile]) -> (actions: [Row], recent: [Row], settings: Row) {
        let actions = [
            Row(icon: "terminal", tint: nil, title: "New terminal", subtitle: nil, shortcut: StartPageView.shortcut("new-tab"), action: newTab),
            Row(icon: "rectangle.stack", tint: nil, title: "Profiles & connections", subtitle: nil,
                shortcut: StartPageView.shortcut("profile-selector"), action: showProfiles),
        ]
        let recent = recents.enumerated().map { i, p in
            Row(icon: ProfileIcons.symbol(for: p.icon ?? (p.type == "ssh" ? "server" : "terminal")),
                tint: p.color.flatMap(RGBColor.init(hex:)), title: p.name, subtitle: Self.subtitle(of: p),
                shortcut: "⌘\(i + 1)", action: { openProfile(p) })
        }
        let settings = Row(icon: "gearshape", tint: nil, title: "Settings", subtitle: nil, shortcut: StartPageView.shortcut("settings"), action: showSettings)
        return (actions, recent, settings)
    }

    static func subtitle(of p: Profile) -> String? {
        if p.type == "ssh" {
            let host = p.options["host"]?.stringValue ?? ""
            let user = p.options["user"]?.stringValue
            return user.map { "\($0)@\(host)" } ?? host
        }
        return p.options["command"]?.stringValue
    }

    var body: some View {
        let _ = AppServices.shared.configRevision
        let r = rows(recents: StartPageView.recentProfiles())
        let all = r.actions + r.recent + [r.settings]
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(chrome.surfaceRaised.color)
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(chrome.border.color, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
                        .frame(width: 84, height: 84)
                        .overlay(Image(systemName: "chevron.right").font(.system(size: 44, weight: .bold)).foregroundStyle(chrome.accent.color))
                    Text("TabbyMac").font(ChromeFont.largeTitle).tracking(-0.5)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(r.actions.enumerated()), id: \.offset) { i, row in item(row, index: i) }
                    if !r.recent.isEmpty {
                        Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(chrome.textFaint.color)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                        ForEach(Array(r.recent.enumerated()), id: \.offset) { i, row in item(row, index: r.actions.count + i) }
                    }
                    Rectangle().fill(chrome.separator.color).frame(height: 1).padding(.vertical, 4)
                    item(r.settings, index: all.count - 1)
                }
                .padding(6)
                .frame(width: 440)
                .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surfaceRaised.color))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chrome.border.color, lineWidth: 0.5))
            }
            .padding(.bottom, 40)
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(chrome.text.color)
        .background(chrome.windowBackground.color)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.downArrow) { selection = min(all.count - 1, selection + 1); return .handled }
        .onKeyPress(.return) {
            if all.indices.contains(selection) { all[selection].action() }
            return .handled
        }
    }

    private func item(_ row: Row, index: Int) -> some View {
        let selected = index == selection
        return Button(action: row.action) {
            HStack(spacing: 10) {
                Image(systemName: row.icon).font(.system(size: 15))
                    .foregroundStyle((row.tint ?? (index == 0 ? chrome.accent : chrome.textMuted)).color)
                    .frame(width: 20)
                Text(row.title).font(ChromeFont.bodyEmphasised).lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if selected { Keycap("↩ open") }
                if let shortcut = row.shortcut {
                    Text(shortcut).font(ChromeFont.caption).foregroundStyle(chrome.textFaint.color)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? chrome.fill.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selection = index } }
    }

    private var footer: some View {
        HStack(spacing: 20) {
            Link(destination: StartPageView.repositoryURL) {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: StartPageView.repositoryURL.appendingPathComponent("issues/new")) {
                Label("Report a problem", systemImage: "ladybug")
            }
            Spacer()
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build")")
                .font(.custom("Menlo", size: 11)).foregroundStyle(chrome.textFaint.color)
        }
        .font(ChromeFont.caption)
        .foregroundStyle(chrome.textMuted.color)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .top) { Rectangle().fill(chrome.separator.color).frame(height: 1) }
    }
}
#endif
