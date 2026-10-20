#if canImport(AppKit)
import SwiftUI
import TabbyCore

/// Shown when a window has no tabs (Tabby's `StartPageComponent`).
struct StartPageView: View {
    var newTab: () -> Void
    var showProfiles: () -> Void
    var showSettings: () -> Void
    var openProfile: (Profile) -> Void

    var body: some View {
        let services = AppServices.shared
        let chrome = services.theme.chrome
        let _ = services.configRevision
        let recents = Array(services.profiles.recents.load().prefix(services.config.int("terminal.showRecentProfiles") ?? 3))
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(chrome.accent.color)
                Text("TabbyMac").font(.largeTitle.weight(.semibold))
            }
            VStack(spacing: 2) {
                StartPageRow(icon: "plus.rectangle", title: "New terminal", shortcut: Self.shortcut("new-tab"), action: newTab)
                StartPageRow(icon: "rectangle.stack", title: "Profiles & connections", shortcut: Self.shortcut("profile-selector"), action: showProfiles)
                ForEach(Array(recents.enumerated()), id: \.offset) { _, p in
                    StartPageRow(icon: ProfileIcons.symbol(for: p.icon ?? "terminal"), title: p.name, shortcut: nil) { openProfile(p) }
                }
                StartPageRow(icon: "gearshape", title: "Settings", shortcut: Self.shortcut("settings"), action: showSettings)
            }
            .frame(width: 360)
            Spacer()
            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build")
                .font(.caption)
                .foregroundStyle(chrome.textMuted.color)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surface.color)
    }

    static func shortcut(_ id: String) -> String? {
        HotkeyBinding.bindings(from: AppServices.shared.config.value("hotkeys.\(id)")).first?.symbolicDescription
    }
}

struct StartPageRow: View {
    let icon: String
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let chrome = AppServices.shared.theme.chrome
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 22)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(chrome.textMuted.color).font(.callout) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(hovering ? chrome.surfaceRaised.color : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
#endif
