#if canImport(AppKit)
import SwiftUI
import TabbyCore

/// When the first-run Welcome tab shows: on a launch that restores no tabs, until "Close and
/// never show again" (Tabby's `enableWelcomeTab`). A restored session keeps its selected tab.
@MainActor
enum WelcomePolicy {
    static func shouldShow(config: ConfigStore, restoredTabs: Bool) -> Bool {
        !restoredTabs && (config.value("enableWelcomeTab")?.boolValue ?? true)
    }

    static func dismissForever(config: ConfigStore) {
        config.set("enableWelcomeTab", false)
    }
}

/// The first-run tab from the design (Tabby's `WelcomeTabComponent`): appearance and the
/// global hotkey, all changeable later in Settings.
struct WelcomeView: View {
    let close: () -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        let _ = AppServices.shared.configRevision
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Welcome to TabbyMac")).font(.system(size: 24, weight: .semibold))
                    Text(L("A few choices before you start. All of them can be changed later in Settings."))
                        .foregroundStyle(chrome.textMuted.color)
                }
                SettingsGroup {
                    SettingsRow(L("Language")) { LanguagePicker() }
                    SettingsRow(L("Appearance")) {
                        Picker("", selection: ConfigBinding.string("appearance.colorSchemeMode")) {
                            Text(L("System")).tag("auto")
                            Text(L("Dark")).tag("dark")
                            Text(L("Light")).tag("light")
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    SettingsRow(L("Global hotkey"), subtitle: L("Show and hide TabbyMac from any app with ⌃Space"),
                                isOn: Self.globalHotkey)
                }
                HStack {
                    Spacer()
                    Button(action: {
                        WelcomePolicy.dismissForever(config: AppServices.shared.config)
                        close()
                    }) {
                        HStack(spacing: 8) {
                            Text(L("Close and never show again"))
                            Text("↩").font(.system(size: 11)).opacity(0.75)
                        }
                    }
                    .buttonStyle(ChromeButtonStyle(kind: .primary, large: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(width: 540)
            .padding(.top, 96)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(chrome.text.color)
        .background(chrome.surface.color)
    }

    /// On binds ⌃Space to `toggle-window` (Tabby's default); off clears the binding.
    @MainActor
    static var globalHotkey: Binding<Bool> {
        Binding(get: {
            _ = AppServices.shared.configRevision
            return !(AppServices.shared.config.value("hotkeys.toggle-window")?.arrayValue ?? []).isEmpty
        }, set: { on in
            AppServices.shared.config.set("hotkeys.toggle-window", on ? .array([.string("Ctrl-Space")]) : .array([]))
        })
    }
}

/// The body of a Settings or Welcome tab.
struct ContentTabView: View {
    let tab: TabModel
    let close: () -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        Group {
            switch tab.content {
            case .settings?:
                if let navigation = tab.settingsNavigation { SettingsRootView(navigation: navigation) }
            case .welcome?:
                WelcomeView(close: close)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.surface.color)
    }
}

/// Root of a content tab's hosting view; applies the theme environment.
struct ContentTabRoot: View {
    let tab: TabModel
    let close: () -> Void

    var body: some View {
        ContentTabView(tab: tab, close: close).chromeEnvironment()
    }
}
#endif
