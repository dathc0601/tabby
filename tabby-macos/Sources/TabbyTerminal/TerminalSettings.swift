import Foundation
import TabbyCore

/// The `terminal.*` settings a terminal pane needs, read from `ConfigStore`.
public struct TerminalSettings: Equatable {
    public enum CursorShape: String { case block, beam, underline }
    public enum BellMode: String { case off, visual, audible }
    public enum RightClick: String { case menu, paste, clipboard, off }

    public var fontName: String
    public var fontSize: Double
    public var fontWeight: Int
    public var fallbackFont: String?
    public var cursor: CursorShape
    public var cursorBlink: Bool
    public var scrollbackLines: Int
    public var bell: BellMode
    /// Tabby's `terminal.bellFlashFrame`: the bell bounces the Dock icon while the app is in
    /// the background (Electron's `flashFrame`).
    public var bellFlashFrame: Bool
    public var copyOnSelect: Bool
    /// Tabby's `clickableLinks.modifier`: the key a click on a link needs.
    public var linkModifier: LinkModifier
    /// Tabby's `terminal.sixel`: whether programs are told the terminal shows Sixel images.
    public var sixel: Bool
    /// Tabby's `terminal.focusFollowsMouse`.
    public var focusFollowsMouse: Bool
    /// Tabby's `terminal.copyAsHTML` ("Copy with formatting"): copies carry HTML too.
    public var copyAsHTML: Bool
    /// Tabby's `terminal.wordSeparator`: where a double-click selection stops.
    public var wordSeparator: String
    public var rightClick: RightClick
    public var pasteOnMiddleClick: Bool
    public var altIsMeta: Bool
    public var bracketedPaste: Bool
    public var warnOnMultilinePaste: Bool
    public var trimWhitespaceOnPaste: Bool
    public var replaceNewlinesWithSpacesOnPaste: Bool
    public var detectProgress: Bool
    public var scrollOnInput: Bool
    public var drawBoldTextInBrightColors: Bool
    public var minimumContrastRatio: Double
    public var useSchemeBackground: Bool
    public var environment: [String: String]

    public init(config c: ConfigStore) {
        fontName = c.string("terminal.font") ?? "Menlo" // l10n-ignore: a font name
        fontSize = c.double("terminal.fontSize") ?? 14
        fontWeight = c.int("terminal.fontWeight") ?? 400
        fallbackFont = c.string("terminal.fallbackFont")
        cursor = CursorShape(rawValue: c.string("terminal.cursor") ?? "block") ?? .block
        cursorBlink = c.value("terminal.cursorBlink")?.boolValue ?? true
        scrollbackLines = c.int("terminal.scrollbackLines") ?? 25000
        bell = BellMode(rawValue: c.string("terminal.bell") ?? "off") ?? .off
        bellFlashFrame = c.bool("terminal.bellFlashFrame")
        copyOnSelect = c.bool("terminal.copyOnSelect")
        focusFollowsMouse = c.bool("terminal.focusFollowsMouse")
        sixel = c.value("terminal.sixel")?.boolValue ?? true
        linkModifier = LinkModifier(config: c.string("clickableLinks.modifier"))
        copyAsHTML = c.value("terminal.copyAsHTML")?.boolValue ?? true
        wordSeparator = c.string("terminal.wordSeparator") ?? TerminalTextDefaults.wordSeparator
        rightClick = RightClick(rawValue: c.string("terminal.rightClick") ?? "menu") ?? .menu
        pasteOnMiddleClick = c.value("terminal.pasteOnMiddleClick")?.boolValue ?? true
        altIsMeta = c.bool("terminal.altIsMeta")
        bracketedPaste = c.value("terminal.bracketedPaste")?.boolValue ?? true
        warnOnMultilinePaste = c.value("terminal.warnOnMultilinePaste")?.boolValue ?? true
        trimWhitespaceOnPaste = c.value("terminal.trimWhitespaceOnPaste")?.boolValue ?? true
        replaceNewlinesWithSpacesOnPaste = c.bool("terminal.replaceNewlinesWithSpacesOnPaste")
        detectProgress = c.value("terminal.detectProgress")?.boolValue ?? true
        scrollOnInput = c.value("terminal.scrollOnInput")?.boolValue ?? true
        drawBoldTextInBrightColors = c.value("terminal.drawBoldTextInBrightColors")?.boolValue ?? true
        minimumContrastRatio = c.double("terminal.minimumContrastRatio") ?? 4
        useSchemeBackground = c.string("terminal.background") == "colorScheme"
        environment = (c.value("terminal.environment")?.objectValue ?? [:]).compactMapValues(\.stringValue)
    }
}
