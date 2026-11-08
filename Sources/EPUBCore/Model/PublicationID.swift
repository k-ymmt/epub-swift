import Foundation

/// Identifier the library assigns to each opened EPUB (docs/design/00-overview.md §5.3).
///
/// Used as the host of `epub://<id>/...` URLs and as a cache key. `dc:identifier` is not used for this
/// because distinct files can share the same value.
public struct PublicationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let uuid: UUID

    public init(uuid: UUID = UUID()) {
        self.uuid = uuid
    }

    /// Parses the lowercase UUID string form produced by `description`.
    public init?(_ description: String) {
        guard let uuid = UUID(uuidString: description) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString.lowercased() }
}
