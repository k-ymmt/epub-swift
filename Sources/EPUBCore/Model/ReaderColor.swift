import Foundation

/// Platform-independent sRGB color (docs/design/03-api.md §2.5). EPUBCore does not import SwiftUI,
/// so colors that cross the API boundary use this type; EPUBUI converts to and from `Color`.
public struct ReaderColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB` convenience.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// CSS color string, e.g. `rgba(28, 28, 30, 1)`.
    public var cssString: String {
        let r = Int((red * 255).rounded()), g = Int((green * 255).rounded()), b = Int((blue * 255).rounded())
        return "rgba(\(r), \(g), \(b), \(alpha))"
    }
}
