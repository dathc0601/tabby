#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// Tabby's profile and group icons are Font Awesome class names (`fas fa-server`); TabbyMac
/// draws SF Symbols for the names it knows and keeps the others as they are.
enum ProfileIcons {
    /// Font Awesome names (without `fa-`) and the SF Symbol drawn for each.
    static let catalog: [(fa: String, symbol: String)] = [ // l10n-ignore: Font Awesome and SF Symbol names
        ("terminal", "terminal"), ("server", "server.rack"), ("desktop", "desktopcomputer"), ("laptop", "laptopcomputer"),
        ("laptop-code", "laptopcomputer"), ("globe", "globe"), ("globe-europe", "globe.europe.africa"),
        ("globe-americas", "globe.americas"), ("globe-asia", "globe.asia.australia"), ("cloud", "cloud"),
        ("cloud-download-alt", "icloud.and.arrow.down"), ("cloud-upload-alt", "icloud.and.arrow.up"), ("database", "cylinder"),
        ("hdd", "internaldrive"), ("memory", "memorychip"), ("microchip", "cable.connector"), ("usb", "cable.connector"),
        ("network-wired", "network"), ("network", "network"), ("ethernet", "network"), ("wifi", "wifi"),
        ("broadcast-tower", "antenna.radiowaves.left.and.right"), ("signal", "antenna.radiowaves.left.and.right"),
        ("plug", "powerplug"), ("power-off", "power"), ("bolt", "bolt"), ("code", "chevron.left.forwardslash.chevron.right"),
        ("code-branch", "arrow.triangle.branch"), ("git", "arrow.triangle.branch"), ("git-alt", "arrow.triangle.branch"),
        ("github", "chevron.left.forwardslash.chevron.right"), ("docker", "shippingbox"), ("box", "shippingbox"),
        ("cube", "cube"), ("cubes", "cube"), ("archive", "archivebox"), ("apple", "apple.logo"), ("linux", "terminal"),
        ("windows", "macwindow"), ("raspberry-pi", "cpu"), ("folder", "folder"), ("folder-open", "folder"),
        ("home", "house"), ("house", "house"), ("building", "building.2"), ("industry", "building.2"), ("user", "person"),
        ("users", "person.2"), ("user-secret", "person.badge.key"), ("id-badge", "person.text.rectangle"),
        ("id-card", "person.text.rectangle"), ("fingerprint", "touchid"), ("lock", "lock"), ("unlock", "lock.open"),
        ("key", "key"), ("shield", "shield"), ("shield-alt", "shield"), ("star", "star"), ("heart", "heart"),
        ("bug", "ladybug"), ("cog", "gearshape"), ("cogs", "gearshape.2"), ("gear", "gearshape"), ("wrench", "wrench"),
        ("tools", "wrench.and.screwdriver"), ("hammer", "hammer"), ("paper-plane", "paperplane"), ("envelope", "envelope"),
        ("phone", "phone"), ("mobile", "iphone"), ("mobile-alt", "iphone"), ("tablet", "ipad"), ("tv", "tv"),
        ("camera", "camera"), ("video", "video"), ("music", "music.note"), ("headphones", "headphones"),
        ("gamepad", "gamecontroller"), ("print", "printer"), ("keyboard", "keyboard"), ("mouse", "computermouse"),
        ("window-maximize", "macwindow"), ("window-restore", "macwindow.on.rectangle"), ("save", "square.and.arrow.down"),
        ("sd-card", "sdcard"), ("battery-full", "battery.100"), ("battery-half", "battery.50"), ("file", "doc"),
        ("file-alt", "doc.text"), ("file-code", "doc.text"), ("book", "book"), ("address-book", "book.closed"),
        ("bookmark", "bookmark"), ("tag", "tag"), ("tags", "tag"), ("flag", "flag"), ("bell", "bell"), ("clock", "clock"),
        ("calendar", "calendar"), ("chart-line", "chart.xyaxis.line"), ("chart-bar", "chart.bar"), ("chart-pie", "chart.pie"),
        ("tachometer-alt", "gauge"), ("search", "magnifyingglass"), ("eye", "eye"), ("fire", "flame"), ("leaf", "leaf"),
        ("sun", "sun.max"), ("moon", "moon"), ("snowflake", "snowflake"), ("lightbulb", "lightbulb"), ("magic", "wand.and.stars"),
        ("puzzle-piece", "puzzlepiece"), ("graduation-cap", "graduationcap"), ("briefcase", "briefcase"),
        ("shopping-cart", "cart"), ("credit-card", "creditcard"), ("money-bill", "banknote"), ("dollar-sign", "dollarsign"),
        ("map", "map"), ("map-marker-alt", "mappin"), ("location-arrow", "location"), ("compass", "safari"), ("car", "car"),
        ("plane", "airplane"), ("ship", "ferry"), ("bicycle", "bicycle"), ("train", "tram"), ("truck", "box.truck"),
        ("list", "list.bullet"), ("th", "square.grid.3x3"), ("th-large", "square.grid.2x2"), ("layer-group", "square.3.layers.3d"),
        ("stream", "line.3.horizontal"), ("random", "shuffle"), ("sync", "arrow.triangle.2.circlepath"), ("redo", "arrow.clockwise"),
        ("undo", "arrow.counterclockwise"), ("exchange-alt", "arrow.left.arrow.right"), ("link", "link"), ("paperclip", "paperclip"),
        ("pen", "pencil"), ("pencil-alt", "pencil"), ("edit", "square.and.pencil"), ("trash", "trash"), ("check", "checkmark"),
        ("check-circle", "checkmark.circle"), ("times", "xmark"), ("times-circle", "xmark.circle"),
        ("exclamation-triangle", "exclamationmark.triangle"), ("info-circle", "info.circle"), ("question-circle", "questionmark.circle"),
        ("ban", "nosign"), ("atom", "atom"), ("infinity", "infinity"), ("hashtag", "number"), ("at", "at"), ("percent", "percent"),
        ("asterisk", "asterisk"), ("circle", "circle"), ("square", "square"), ("play", "play"), ("stop", "stop"), ("pause", "pause"),
        ("comment", "bubble.left"), ("comments", "bubble.left.and.bubble.right"), ("inbox", "tray"),
        ("download", "arrow.down.circle"), ("upload", "arrow.up.circle"), ("sitemap", "list.bullet.indent"),
    ]

    private static let symbols = Dictionary(catalog.map { ($0.fa, $0.symbol) }, uniquingKeysWith: { a, _ in a })

    /// The Font Awesome name in a class list (`fas fa-server`, `far fa-folder`, `fa-solid
    /// fa-server`, or a bare `server` from earlier TabbyMac builds).
    static func name(of icon: String) -> String {
        let tokens = icon.split(separator: " ").map(String.init)
        let styles: Set<String> = ["fa-fw", "fa-solid", "fa-regular", "fa-brands", "fa-light", "fa-thin", "fa-duotone"] // l10n-ignore: Font Awesome classes
        if let token = tokens.last(where: { $0.hasPrefix("fa-") && !styles.contains($0) }) { return String(token.dropFirst(3)) }
        return tokens.last ?? icon
    }

    /// Whether TabbyMac has a symbol for the icon.
    static func isKnown(_ icon: String) -> Bool { symbols[name(of: icon)] != nil }

    /// The SF Symbol for an icon; one TabbyMac doesn't know draws as a terminal.
    static func symbol(for icon: String) -> String { symbols[name(of: icon)] ?? "terminal" }

    /// What the picker writes: Tabby's class name for the solid style.
    static func className(_ fa: String) -> String { "fas fa-" + fa } // l10n-ignore: Font Awesome class

    /// The icon of a profile that has none (Tabby's providers set these on their builtins).
    static func defaultIcon(forType type: String) -> String {
        switch type {
        case "ssh": return "server"
        case "serial": return "fas fa-microchip" // l10n-ignore: Font Awesome icon names
        case "telnet": return "fas fa-network-wired" // l10n-ignore: Font Awesome icon names
        default: return "terminal"
        }
    }
}

/// Tabby's named tab colours (`TAB_COLORS` in tabby-core/src/utils.ts).
enum ProfileColors {
    static let named: [(name: String, value: String)] = [
        (Lkey("Blue"), "#0275d8"), (Lkey("Green"), "#5cb85c"), (Lkey("Orange"), "#f0ad4e"),
        (Lkey("Purple"), "#613d7c"), (Lkey("Red"), "#d9534f"), (Lkey("Yellow"), "#ffd500"),
    ]

    /// The colour a profile or group colour stands for: a hex value, or a CSS colour name
    /// Tabby accepts in the text field.
    static func rgb(_ value: String) -> RGBColor? {
        if let c = RGBColor(hex: value) { return c }
        let css: [String: String] = ["red": "#ff0000", "green": "#008000", "blue": "#0000ff", "yellow": "#ffff00", // l10n-ignore: CSS colour names
                                     "orange": "#ffa500", "purple": "#800080", "teal": "#008080", "pink": "#ffc0cb", // l10n-ignore: CSS colour names
                                     "gray": "#808080", "grey": "#808080", "black": "#000000", "white": "#ffffff", "cyan": "#00ffff", // l10n-ignore: CSS colour names
                                     "magenta": "#ff00ff", "brown": "#a52a2a", "navy": "#000080"] // l10n-ignore: CSS colour names
        return css[value.lowercased()].flatMap { RGBColor(hex: $0) }
    }
}

/// The icon field of the profile and group editors: the current symbol, which opens a
/// searchable grid of the icons TabbyMac can draw.
struct ProfileIconPicker: View {
    @Binding var icon: String?
    var placeholder: String = "terminal"
    @State private var open = false
    @State private var query = ""
    @Environment(\.chrome) private var chrome

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 6) {
                Image(systemName: ProfileIcons.symbol(for: icon ?? placeholder)).frame(width: 18)
                Text(label).lineLimit(1).fixedSize() // M12 walk: "Default" was cut to "D…"
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(chrome.textFaint.color)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(chrome.fill.color))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("Search icons"), text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 9), spacing: 4) {
                        cell(nil)
                        ForEach(Self.matches(query), id: \.fa) { entry in cell(entry.fa) }
                    }
                }
                .frame(width: 300, height: 220)
            }
            .padding(10)
        }
    }

    private var label: String {
        guard let icon else { return L("Default") }
        return ProfileIcons.isKnown(icon) ? ProfileIcons.name(of: icon) : L("Custom: {icon}", ["icon": icon])
    }

    static func matches(_ query: String) -> [(fa: String, symbol: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? ProfileIcons.catalog : ProfileIcons.catalog.filter { $0.fa.contains(q) || $0.symbol.contains(q) }
    }

    private func cell(_ fa: String?) -> some View {
        let selected = fa.map { ProfileIcons.name(of: icon ?? "") == $0 } ?? (icon == nil)
        return Button {
            icon = fa.map(ProfileIcons.className)
            open = false
        } label: {
            Image(systemName: fa.map { ProfileIcons.symbol(for: $0) } ?? "circle.dashed")
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? chrome.accentFill.color : .clear))
        }
        .buttonStyle(.plain)
        .help(fa ?? L("Default"))
    }
}

/// The colour field of the profile and group editors: "No color", Tabby's named colours and
/// a colour well for any other; a value from elsewhere (a CSS name, another hex) shows as
/// its own swatch and is kept.
struct ProfileColorPicker: View {
    @Binding var color: String?
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(spacing: 5) {
            Button { color = nil } label: {
                Image(systemName: "nosign").font(.system(size: 13)).foregroundStyle(chrome.textMuted.color)
                    .overlay(Circle().strokeBorder(color == nil ? chrome.text.color : .clear, lineWidth: 2).padding(-3))
            }
            .buttonStyle(.plain)
            .help(L("No color"))
            ForEach(ProfileColors.named, id: \.value) { entry in swatch(entry.value, help: L(entry.name)) }
            if let color, !ProfileColors.named.contains(where: { $0.value.lowercased() == color.lowercased() }) {
                swatch(color, help: color)
            }
            ColorPicker("", selection: Binding(
                get: { (color.flatMap(ProfileColors.rgb) ?? .black).color },
                set: { new in
                    if let c = NSColor(new).usingColorSpace(.sRGB) {
                        color = RGBColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)).hex
                    }
                }), supportsOpacity: false)
                .labelsHidden()
                .help(L("Other color"))
        }
    }

    private func swatch(_ value: String, help: String) -> some View {
        Button { color = value } label: {
            Circle().fill((ProfileColors.rgb(value) ?? .black).color).frame(width: 15, height: 15)
                .overlay(Circle().strokeBorder(color?.lowercased() == value.lowercased() ? chrome.text.color : .clear, lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
#endif
