import Foundation

/// The computed `writing-mode` of the current document as reported by `reader.js` (docs/design/02-rendering.md §3.4).
///
/// Vertical modes page along the y axis (`scrollTop`) and are read right-bound; horizontal modes page along x.
public enum WritingMode: String, Sendable, Hashable, Codable, CaseIterable {
    case horizontalTB = "horizontal-tb"
    case verticalRL = "vertical-rl"
    case verticalLR = "vertical-lr"

    /// Maps a CSS `writing-mode` value. `sideways-*` maps to the matching vertical case; anything unknown is horizontal.
    public init(cssValue: String) {
        switch cssValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "vertical-rl", "sideways-rl", "tb-rl", "tb": self = .verticalRL
        case "vertical-lr", "sideways-lr", "tb-lr": self = .verticalLR
        default: self = .horizontalTB
        }
    }

    /// Pages are stacked along the y axis and scrolled with `scrollTop`.
    public var isVertical: Bool { self != .horizontalTB }

    /// Whether a book in this writing mode is read right-to-left by default (`vertical-rl`).
    public var isRightToLeftByDefault: Bool { self == .verticalRL }
}
