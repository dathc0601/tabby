#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// Raw config.yaml editor (Tabby's Config file page): line numbers, syntax colours from the
/// scheme's ANSI colours, and live validation. Saving a top level that is not a mapping is
/// refused by `ConfigStore.replaceUser`, so a stray word can't wipe every setting.
struct ConfigFileSettingsView: View {
    @State private var text = ""
    @State private var saveError: String?
    @State private var showDefaults = false
    @Environment(\.chrome) private var chrome

    var body: some View {
        let services = AppServices.shared
        let problem = Self.problem(in: text)
        VStack(alignment: .leading, spacing: 14) {
            ConfigFileHeader(problem: problem, showDefaults: $showDefaults,
                             showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([services.paths.configFile]) },
                             revert: load, save: save)
            if let saveError {
                Text(saveError).font(ChromeFont.callout).foregroundStyle(chrome.danger.color)
            }
            YAMLEditor(text: $text, isEditable: !showDefaults, scheme: services.theme.scheme)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chrome.border.color, lineWidth: 0.5))
        }
        .padding(24)
        .onAppear(perform: load)
        .onChange(of: showDefaults) { load() }
    }

    /// Why the text can't be saved, or nil.
    static func problem(in text: String) -> String? {
        do {
            let value = try YAMLCoding.parse(text)
            return value.objectValue != nil || value == .null ? nil : "The top level must be a mapping"
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Not valid YAML"
        }
    }

    private func load() {
        let config = AppServices.shared.config
        if showDefaults {
            text = (try? YAMLCoding.serialize(config.defaults.strippingMarkers())) ?? ""
        } else {
            text = (try? config.serializedUserConfig()) ?? ""
        }
        saveError = nil
    }

    private func save() {
        do {
            let value = try YAMLCoding.parse(text)
            try AppServices.shared.config.replaceUser(value)
            AppServices.shared.flushSave()
            saveError = nil
        } catch {
            saveError = "Not saved: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
    }
}

/// NSTextView with a line-number ruler and YAML colours.
struct YAMLEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var scheme: TabbyCore.ColorScheme

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.delegate = context.coordinator
        scroll.hasVerticalRuler = true
        scroll.verticalRulerView = LineNumberRuler(textView: textView)
        scroll.rulersVisible = true
        scroll.drawsBackground = true
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.scheme = scheme
        textView.isEditable = isEditable
        let bg = scheme.backgroundRGB.nsColor
        textView.backgroundColor = bg
        scroll.backgroundColor = bg
        textView.insertionPointColor = scheme.foregroundRGB.nsColor
        (scroll.verticalRulerView as? LineNumberRuler)?.colors = (bg, scheme.foregroundRGB.mixOKLab(scheme.backgroundRGB, 0.58).nsColor)
        if textView.string != text {
            textView.string = text
        }
        context.coordinator.highlight()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var scheme: TabbyCore.ColorScheme = .tabbyDefault
        weak var textView: NSTextView?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            highlight()
        }

        func highlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let palette = scheme.paletteRGB
            func color(_ i: Int) -> NSColor { (i < palette.count ? palette[i] : scheme.foregroundRGB).nsColor }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: scheme.foregroundRGB.nsColor, range: full)
            for token in YAMLHighlighter.tokens(inDocument: textView.string) {
                let range = NSRange(location: token.range.lowerBound, length: token.range.count)
                guard NSMaxRange(range) <= storage.length else { continue }
                let c: NSColor
                switch token.kind {
                case .key: c = color(4)
                case .string: c = color(2)
                case .number: c = color(3)
                case .bool: c = color(5)
                case .comment: c = color(8)
                }
                storage.addAttribute(.foregroundColor, value: c, range: range)
            }
            storage.endEditing()
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}

/// Line numbers beside an NSTextView.
final class LineNumberRuler: NSRulerView {
    var colors: (background: NSColor, text: NSColor) = (.textBackgroundColor, .secondaryLabelColor) {
        didSet { needsDisplay = true }
    }
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        colors.background.setFill()
        bounds.fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let text = textView.string as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo", size: 11) ?? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: colors.text,
        ]
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let firstChar = layout.characterIndexForGlyph(at: glyphs.location)
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: firstChar), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        if firstChar == 0 { line = 1 }
        var index = firstChar
        let inset = textView.textContainerOrigin.y
        while index <= min(NSMaxRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)), text.length) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = layout.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: max(lineRange.length, 1) - (lineRange.length > 0 ? 0 : 1)), actualCharacterRange: nil)
            var lineRect = layout.lineFragmentRect(forGlyphAt: min(glyphRange.location, max(layout.numberOfGlyphs - 1, 0)), effectiveRange: nil)
            if text.length == 0 { lineRect = NSRect(x: 0, y: 0, width: 0, height: 15) }
            let y = lineRect.minY + inset - visible.minY
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y + (lineRect.height - size.height) / 2), withAttributes: attributes)
            line += 1
            let next = NSMaxRange(lineRange)
            if next <= index || next >= text.length { break }
            index = next
        }
    }
}

/// Title, validation status, Show defaults and the file actions of the Config file page.
struct ConfigFileHeader: View {
    let problem: String?
    @Binding var showDefaults: Bool
    let showInFinder: () -> Void
    let revert: () -> Void
    let save: () -> Void
    @Environment(\.chrome) private var chrome

    /// One row when there is room; in a narrow window two, then three rows, so no label is
    /// squeezed into a column of letters and a YAML error can wrap.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title
                Spacer(minLength: 10)
                status.fixedSize()
                toggle
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    title
                    Spacer(minLength: 10)
                    status.fixedSize()
                }
                HStack(spacing: 10) {
                    toggle
                    Spacer(minLength: 10)
                    actions
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    title
                    Spacer(minLength: 10)
                    toggle
                }
                status.lineLimit(3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    actions
                }
            }
        }
        .font(ChromeFont.body)
    }

    private var title: some View {
        Text("Config file").font(ChromeFont.title).fixedSize()
    }

    @ViewBuilder private var status: some View {
        if showDefaults {
            Label("Defaults (read only)", systemImage: "lock").foregroundStyle(chrome.textMuted.color)
        } else if let problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(chrome.danger.color)
        } else {
            Label("Valid YAML", systemImage: "checkmark.circle.fill").foregroundStyle(chrome.success.color)
        }
    }

    private var toggle: some View {
        Toggle("Show defaults", isOn: $showDefaults).toggleStyle(.switch).controlSize(.small).fixedSize()
    }

    @ViewBuilder private var actions: some View {
        Button("Show in Finder", action: showInFinder).buttonStyle(ChromeButtonStyle()).fixedSize()
        Button("Revert", action: revert).buttonStyle(ChromeButtonStyle()).disabled(showDefaults).fixedSize()
        Button("Save", action: save)
            .buttonStyle(ChromeButtonStyle(kind: .primary))
            .keyboardShortcut("s", modifiers: .command)
            .disabled(showDefaults || problem != nil)
            .fixedSize()
    }
}
#endif
