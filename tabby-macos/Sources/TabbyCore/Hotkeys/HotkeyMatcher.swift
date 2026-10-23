import Foundation

/// Pure chord-aware hotkey matcher (the platform layer turns key events into `Keystroke`s).
///
/// Mirrors `HotkeysService.matchActiveHotkey` in Tabby, simplified to consecutive sequences:
/// the longest binding whose strokes equal the most recent strokes wins. When the recent
/// strokes are a proper prefix of some chord, the result is `.partial` so the caller can
/// swallow the key and wait for the rest.
public final class HotkeyMatcher {
    public enum Result: Equatable {
        case none
        case partial
        case matched(String)
    }

    public private(set) var bindings: [String: [HotkeyBinding]] = [:]
    private var history: [(Keystroke, TimeInterval)] = []
    private var maxChordLength = 1
    public var chordTimeout: TimeInterval = 2.0

    public init(bindings: [String: [HotkeyBinding]] = [:]) {
        setBindings(bindings)
    }

    public func setBindings(_ bindings: [String: [HotkeyBinding]]) {
        self.bindings = bindings
        maxChordLength = bindings.values.flatMap { $0 }.map(\.strokes.count).max() ?? 1
        history.removeAll()
    }

    /// Builds the id -> bindings map from the effective `hotkeys` config subtree, flattening
    /// nested maps (`profile.<id>`, `settings-tab.<id>`) to dotted ids like Tabby does.
    public static func bindings(fromHotkeysConfig value: ConfigValue?) -> [String: [HotkeyBinding]] {
        var result: [String: [HotkeyBinding]] = [:]
        func walk(_ v: ConfigValue, prefix: String) {
            guard let o = v.objectValue else { return }
            for (k, child) in o where k != ConfigValue.nonStructuralKey {
                let id = prefix.isEmpty ? k : "\(prefix).\(k)"
                if child.objectValue != nil {
                    walk(child, prefix: id)
                } else {
                    let b = HotkeyBinding.bindings(from: child)
                    if !b.isEmpty { result[id] = b }
                }
            }
        }
        if let value { walk(value, prefix: "") }
        return result
    }

    public func reset() {
        history.removeAll()
    }

    public func feed(_ stroke: Keystroke, at time: TimeInterval) -> Result {
        if stroke.isModifierOnly { return .none }
        history.removeAll { time - $0.1 > chordTimeout }
        history.append((stroke, time))
        if history.count > maxChordLength { history.removeFirst(history.count - maxChordLength) }
        let recent = history.map(\.0)

        var best: (id: String, length: Int)?
        var hasPartial = false
        for (id, list) in bindings {
            for binding in list {
                let seq = binding.strokes
                if seq.count <= recent.count, Array(recent.suffix(seq.count)) == seq {
                    if best == nil || seq.count > best!.length || (seq.count == best!.length && id < best!.id) {
                        best = (id, seq.count)
                    }
                } else if seq.count > 1 {
                    // Is some suffix of the history a proper prefix of this chord?
                    for n in stride(from: min(recent.count, seq.count - 1), through: 1, by: -1)
                    where Array(recent.suffix(n)) == Array(seq.prefix(n)) {
                        hasPartial = true
                        break
                    }
                }
            }
        }
        if let best {
            if best.length > 1 { history.removeAll() }
            return .matched(best.id)
        }
        if hasPartial { return .partial }
        history.removeAll()
        return .none
    }
}
