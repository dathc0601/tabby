import Foundation
#if canImport(CoreGraphics)
// Newer Apple SDKs no longer re-export CoreGraphics from Foundation; CGRect's
// Equatable conformance and `init(x:y:width:height:)` live in the CoreGraphics overlay.
import CoreGraphics
#endif

/// Which way a container lays out its children. Same letters as Tabby:
/// `h` = side by side (left to right), `v` = stacked (top to bottom).
public enum SplitOrientation: String, Codable, Sendable {
    case horizontal = "h"
    case vertical = "v"
}

/// Side of a pane to split towards (`SplitDirection` in Tabby: t/r/b/l).
public enum SplitDirection: String, CaseIterable, Codable, Sendable {
    case top = "t", right = "r", bottom = "b", left = "l"

    var orientation: SplitOrientation { self == .left || self == .right ? .horizontal : .vertical }
    /// Whether the new pane goes before (top/left) the reference pane.
    var insertsBefore: Bool { self == .left || self == .top }

    /// The drop zone under `point` when a tab is dragged over `rect` (a pane, y down): the
    /// edge nearest the pointer, relative to the pane's width and height.
    public static func dropSide(at point: CGPoint, in rect: CGRect) -> SplitDirection {
        let w = max(rect.width, 1), h = max(rect.height, 1)
        let distances: [(SplitDirection, CGFloat)] = [
            (.left, (point.x - rect.minX) / w), (.right, (rect.maxX - point.x) / w),
            (.top, (point.y - rect.minY) / h), (.bottom, (rect.maxY - point.y) / h),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// The half of `rect` (y down) the new pane takes when dropped on this side.
    public func previewFrame(in rect: CGRect) -> CGRect {
        switch self {
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }
}

/// A split layout tree. Port of `SplitContainer` (`tabby-core/src/components/splitTab.component.ts`).
///
/// Every top-level tab owns one of these; leaves are pane ids. The tree is a value type and
/// every operation is pure, so it is fully unit-tested; views just render `layout(in:)`.
public indirect enum SplitNode: Hashable, Sendable {
    case leaf(UUID)
    case container(SplitContainer)

    public var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .container(let c): return c.children.flatMap(\.leaves)
        }
    }

    public func contains(_ id: UUID) -> Bool { leaves.contains(id) }
}

public struct SplitContainer: Hashable, Sendable {
    public var orientation: SplitOrientation
    public var children: [SplitNode]
    /// Relative sizes of children, summing to 1.
    public var ratios: [Double]

    public init(orientation: SplitOrientation, children: [SplitNode], ratios: [Double]? = nil) {
        self.orientation = orientation
        self.children = children
        self.ratios = ratios ?? Array(repeating: 1.0 / Double(max(children.count, 1)), count: children.count)
    }
}

/// A tab's split layout: the tree root plus convenience operations. The root is always a
/// container, as in Tabby, so a single pane is `container(h, [leaf])`.
public struct SplitLayout: Hashable, Sendable {
    public private(set) var root: SplitContainer

    public init(single pane: UUID) {
        root = SplitContainer(orientation: .horizontal, children: [.leaf(pane)], ratios: [1])
    }

    public init(root: SplitContainer) {
        self.root = root
        normalize()
    }

    public var panes: [UUID] { root.children.flatMap(\.leaves) }
    public var isEmpty: Bool { root.children.isEmpty }

    // MARK: Mutation

    /// Inserts `newPane` next to `relative` on the given side (Tabby's `addTab`).
    /// When `relative` is nil the pane is added at the edge of the whole layout.
    public mutating func insert(_ newPane: UUID, relativeTo relative: UUID?, side: SplitDirection) {
        insert(.leaf(newPane), relativeTo: relative, side: side)
    }

    public mutating func insert(_ thing: SplitNode, relativeTo relative: UUID?, side: SplitDirection) {
        if let relative, let path = path(to: relative), !path.isEmpty {
            let parentPath = Array(path.dropLast())
            let index = path.last!
            var parent = container(at: parentPath)
            if parent.orientation == side.orientation {
                Self.insertChild(&parent, thing, at: index + (side.insertsBefore ? 0 : 1))
            } else {
                // Wrap the relative pane in a new container with the right orientation.
                var wrapper = SplitContainer(orientation: side.orientation, children: [parent.children[index]], ratios: [1])
                Self.insertChild(&wrapper, thing, at: side.insertsBefore ? 0 : 1)
                parent.children[index] = .container(wrapper)
            }
            setContainer(parent, at: parentPath)
        } else {
            if root.orientation != side.orientation && root.children.count > 1 {
                root = SplitContainer(orientation: side.orientation, children: [.container(root)], ratios: [1])
            } else if root.children.count <= 1 {
                root.orientation = side.orientation
            }
            Self.insertChild(&root, thing, at: side.insertsBefore ? 0 : root.children.count)
        }
        normalize()
    }

    private static func insertChild(_ c: inout SplitContainer, _ node: SplitNode, at index: Int) {
        let n = Double(c.children.count)
        for i in c.ratios.indices { c.ratios[i] *= n / (n + 1) }
        let idx = max(0, min(index, c.children.count))
        c.ratios.insert(1 / (n + 1), at: idx)
        c.children.insert(node, at: idx)
    }

    /// Removes a pane (Tabby's `removeTab`). Returns the pane that should receive focus.
    @discardableResult
    public mutating func remove(_ pane: UUID) -> UUID? {
        guard let path = path(to: pane), let index = path.last else { return nil }
        let parentPath = Array(path.dropLast())
        var parent = container(at: parentPath)
        parent.children.remove(at: index)
        parent.ratios.remove(at: index)
        let neighbour = parent.children.isEmpty ? nil : parent.children[min(index, parent.children.count - 1)].leaves.first
        setContainer(parent, at: parentPath)
        normalize()
        return neighbour ?? panes.first
    }

    /// Swaps one pane id for another in place (Tabby's `replaceTab`).
    public mutating func replace(_ pane: UUID, with newPane: UUID) {
        func walk(_ node: SplitNode) -> SplitNode {
            switch node {
            case .leaf(let id): return .leaf(id == pane ? newPane : id)
            case .container(var c):
                c.children = c.children.map(walk)
                return .container(c)
            }
        }
        root.children = root.children.map(walk)
    }

    /// Makes every pane in every container the same size.
    public mutating func equalize() {
        func eq(_ c: inout SplitContainer) {
            for i in c.children.indices {
                if case .container(var inner) = c.children[i] {
                    eq(&inner)
                    c.children[i] = .container(inner)
                }
            }
            c.ratios = Array(repeating: 1 / Double(max(c.children.count, 1)), count: c.children.count)
        }
        eq(&root)
    }

    /// Changes the size of `pane` along `orientation` by `step` (Tabby's `resizePane`).
    /// Returns false when nothing could be resized.
    @discardableResult
    public mutating func resize(_ pane: UUID, orientation: SplitOrientation, by step: Double) -> Bool {
        guard var path = path(to: pane) else { return false }
        while !path.isEmpty {
            let index = path.removeLast()
            var c = container(at: path)
            if c.orientation == orientation && c.children.count > 1 {
                let updated = c.ratios[index] + step
                guard updated > 0, updated < 1 else { return false }
                let delta = updated - c.ratios[index]
                c.ratios[index] = updated
                // Take the space from (or give it to) the siblings proportionally.
                let others = c.ratios.indices.filter { $0 != index }
                let othersSum = others.map { c.ratios[$0] }.reduce(0, +)
                if othersSum > 0 {
                    for i in others { c.ratios[i] -= delta * c.ratios[i] / othersSum }
                }
                setContainer(c, at: path)
                return true
            }
        }
        return false
    }

    /// Sets the ratio boundary between child `index - 1` and child `index` of the container at
    /// `containerPath` (divider drag). `fraction` is the boundary position within the container.
    public mutating func moveDivider(containerPath: [Int], index: Int, to fraction: Double, minimum: Double = 0.05) {
        var c = container(at: containerPath)
        guard index > 0, index < c.children.count else { return }
        let start = c.ratios[..<(index - 1)].reduce(0, +)
        let pairTotal = c.ratios[index - 1] + c.ratios[index]
        let left = max(minimum, min(pairTotal - minimum, fraction - start))
        c.ratios[index - 1] = left
        c.ratios[index] = pairTotal - left
        setContainer(c, at: containerPath)
    }

    // MARK: Normalization

    /// Removes empty and single-child containers, flattens nested containers with the same
    /// orientation and renormalizes ratios (Tabby's `normalize`).
    public mutating func normalize() {
        root = Self.normalized(root)
        // A root holding one container: hoist it, keeping the root a container.
        if root.children.count == 1, case .container(let inner) = root.children[0] {
            root = inner
        }
    }

    static func normalized(_ c: SplitContainer) -> SplitContainer {
        var children: [SplitNode] = []
        var ratios: [Double] = []
        for (i, child) in c.children.enumerated() {
            let ratio = i < c.ratios.count ? c.ratios[i] : 1.0 / Double(c.children.count)
            switch child {
            case .leaf:
                children.append(child)
                ratios.append(ratio)
            case .container(let inner):
                let n = normalized(inner)
                if n.children.isEmpty { continue }
                if n.children.count == 1 {
                    children.append(n.children[0])
                    ratios.append(ratio)
                } else if n.orientation == c.orientation {
                    for (j, grand) in n.children.enumerated() {
                        children.append(grand)
                        ratios.append(n.ratios[j] * ratio)
                    }
                } else {
                    children.append(.container(n))
                    ratios.append(ratio)
                }
            }
        }
        let sum = ratios.reduce(0, +)
        if sum > 0 { ratios = ratios.map { $0 / sum } }
        return SplitContainer(orientation: c.orientation, children: children, ratios: ratios)
    }

    // MARK: Geometry

    /// Pane rectangles for a given bounds, in a top-left-origin coordinate space.
    public func layout(in rect: CGRect, spacing: CGFloat = 0) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        func place(_ c: SplitContainer, _ r: CGRect) {
            var offset: CGFloat = 0
            let total = c.orientation == .horizontal ? r.width : r.height
            let available = max(0, total - spacing * CGFloat(max(c.children.count - 1, 0)))
            for (i, child) in c.children.enumerated() {
                let size = available * CGFloat(c.ratios[i])
                let childRect: CGRect = c.orientation == .horizontal
                    ? CGRect(x: r.minX + offset, y: r.minY, width: size, height: r.height)
                    : CGRect(x: r.minX, y: r.minY + offset, width: r.width, height: size)
                offset += size + spacing
                switch child {
                case .leaf(let id): result[id] = childRect.integral
                case .container(let inner): place(inner, childRect)
                }
            }
        }
        place(root, rect)
        return result
    }

    public struct Divider: Equatable {
        /// Path of indices from the root to the container.
        public var containerPath: [Int]
        /// The divider sits between child `index - 1` and child `index`.
        public var index: Int
        public var orientation: SplitOrientation
        public var frame: CGRect
        /// The container's frame, for converting drag positions into fractions.
        public var containerFrame: CGRect
    }

    /// Dividers between panes, for hit-testing and drawing.
    public func dividers(in rect: CGRect, spacing: CGFloat, thickness: CGFloat) -> [Divider] {
        var result: [Divider] = []
        func walk(_ c: SplitContainer, _ r: CGRect, _ path: [Int]) {
            var offset: CGFloat = 0
            let total = c.orientation == .horizontal ? r.width : r.height
            let available = max(0, total - spacing * CGFloat(max(c.children.count - 1, 0)))
            for (i, child) in c.children.enumerated() {
                let size = available * CGFloat(c.ratios[i])
                let childRect: CGRect = c.orientation == .horizontal
                    ? CGRect(x: r.minX + offset, y: r.minY, width: size, height: r.height)
                    : CGRect(x: r.minX, y: r.minY + offset, width: r.width, height: size)
                if i > 0 {
                    let mid = (c.orientation == .horizontal ? childRect.minX : childRect.minY) - spacing / 2
                    let f: CGRect = c.orientation == .horizontal
                        ? CGRect(x: mid - thickness / 2, y: r.minY, width: thickness, height: r.height)
                        : CGRect(x: r.minX, y: mid - thickness / 2, width: r.width, height: thickness)
                    result.append(Divider(containerPath: path, index: i, orientation: c.orientation, frame: f, containerFrame: r))
                }
                offset += size + spacing
                if case .container(let inner) = child { walk(inner, childRect, path + [i]) }
            }
        }
        walk(root, rect, [])
        return result
    }

    /// The nearest pane in a direction, using the same centre-distance metric as Tabby's
    /// `getNearestPaneInDirection`. Returns `from` when there is none.
    public func neighbour(of from: UUID, direction: SplitDirection, in rect: CGRect = CGRect(x: 0, y: 0, width: 1000, height: 1000)) -> UUID {
        let frames = layout(in: rect)
        guard let r = frames[from] else { return from }
        let candidates = frames.filter { id, f in
            guard id != from else { return false }
            switch direction {
            case .left: return f.maxX <= r.minX + 0.5
            case .right: return f.minX >= r.maxX - 0.5
            case .top: return f.maxY <= r.minY + 0.5
            case .bottom: return f.minY >= r.maxY - 0.5
            }
        }
        // Ties go to the pane that comes first in layout order, like Tabby's strict `<` scan.
        let order = Dictionary(uniqueKeysWithValues: panes.enumerated().map { ($1, $0) })
        let best = candidates.min { a, b in
            func d(_ f: CGRect) -> CGFloat { abs(r.midX - f.midX) + abs(r.midY - f.midY) }
            return d(a.value) != d(b.value) ? d(a.value) < d(b.value) : (order[a.key] ?? 0) < (order[b.key] ?? 0)
        }
        return best?.key ?? from
    }

    /// Linear navigation in tree order (Tabby's `navigateLinear`).
    public func pane(after pane: UUID, delta: Int) -> UUID {
        let all = panes
        guard let i = all.firstIndex(of: pane), !all.isEmpty else { return pane }
        return all[((i + delta) % all.count + all.count) % all.count]
    }

    // MARK: Paths

    /// Indices from the root to the node containing `pane` (last index = position in its parent).
    public func path(to pane: UUID) -> [Int]? {
        func search(_ c: SplitContainer, _ prefix: [Int]) -> [Int]? {
            for (i, child) in c.children.enumerated() {
                switch child {
                case .leaf(let id) where id == pane: return prefix + [i]
                case .container(let inner):
                    if let p = search(inner, prefix + [i]) { return p }
                default: continue
                }
            }
            return nil
        }
        return search(root, [])
    }

    func container(at path: [Int]) -> SplitContainer {
        var c = root
        for i in path {
            guard case .container(let inner) = c.children[i] else { return c }
            c = inner
        }
        return c
    }

    mutating func setContainer(_ newValue: SplitContainer, at path: [Int]) {
        func set(_ c: inout SplitContainer, _ path: ArraySlice<Int>) {
            guard let first = path.first else { c = newValue; return }
            guard case .container(var inner) = c.children[first] else { return }
            set(&inner, path.dropFirst())
            c.children[first] = .container(inner)
        }
        set(&root, path[...])
    }
}
