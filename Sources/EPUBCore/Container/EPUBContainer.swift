import Foundation

/// An opened EPUB: the ZIP plus its parsed `Publication` (docs/design/01-core.md §1.2, 03-api §2.1).
///
/// Opening parses `container.xml` → OPF → nav. Resources are decompressed on demand; small text resources are
/// cached. Spine documents go through `XHTMLRepair` once and the result is cached per path.
public actor EPUBContainer {
    public nonisolated let id: PublicationID
    public nonisolated let publication: Publication
    /// The file this container was opened from, if any.
    public nonisolated let url: URL?

    private let archive: ZIPArchive
    /// Container path → font obfuscation to undo (docs/design/01-core.md §2.4).
    private let obfuscations: [String: FontObfuscation]
    /// Container paths encrypted with an unsupported algorithm; reading them throws `EPUBError.encryptedResource`.
    private let unsupportedEncryptedPaths: Set<String>
    private let cache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 16 * 1024 * 1024
        return c
    }()
    /// Prepared spine documents; seeded at open (the character counts need the parse anyway).
    private var contentDocuments: [String: ContentDocument]

    public init(url: URL) async throws {
        let loaded = try await Task.detached(priority: .userInitiated) {
            try Loader.load(url: url)
        }.value
        self.id = loaded.publication.id
        self.publication = loaded.publication
        self.url = url
        self.archive = loaded.archive
        self.obfuscations = loaded.obfuscations
        self.unsupportedEncryptedPaths = loaded.unsupportedEncryptedPaths
        self.contentDocuments = loaded.contentDocuments
    }

    /// Opens an EPUB held in memory (tests, documents received as data).
    public init(data: Data) async throws {
        let loaded = try await Task.detached(priority: .userInitiated) {
            try Loader.load(data: data, url: nil)
        }.value
        self.id = loaded.publication.id
        self.publication = loaded.publication
        self.url = nil
        self.archive = loaded.archive
        self.obfuscations = loaded.obfuscations
        self.unsupportedEncryptedPaths = loaded.unsupportedEncryptedPaths
        self.contentDocuments = loaded.contentDocuments
    }

    /// Container paths of every file in the ZIP.
    public nonisolated var paths: [String] {
        Array(archive.entries.keys)
    }

    public nonisolated func contains(path: String) -> Bool {
        archive.contains(path)
    }

    /// Bytes of a resource, with font obfuscation undone (docs/design/01-core.md §2.4). Throws
    /// `EPUBError.encryptedResource` for resources encrypted with an unsupported algorithm.
    public func data(at path: String) throws -> Data {
        let normalized = ContainerPath.normalize(path)
        if let cached = cache.object(forKey: normalized as NSString) {
            return cached as Data
        }
        if unsupportedEncryptedPaths.contains(normalized) {
            throw EPUBError.encryptedResource(path: normalized)
        }
        var data = try archive.data(at: normalized)
        if let obfuscation = obfuscations[normalized] {
            data = obfuscation.apply(to: data)
        }
        if shouldCache(path: normalized, size: data.count) {
            cache.setObject(data as NSData, forKey: normalized as NSString, cost: data.count)
        }
        return data
    }

    public func coverImageData() throws -> Data? {
        guard let path = publication.coverImagePath else { return nil }
        return try data(at: path)
    }

    /// A spine document prepared for serving: original bytes when well-formed, otherwise the repaired XML or the
    /// `text/html` fallback (docs/design/01-core.md §4.1). The result is cached.
    public func contentDocument(at path: String) throws -> ContentDocument {
        let normalized = ContainerPath.normalize(path)
        if let cached = contentDocuments[normalized] { return cached }
        let data = try data(at: normalized)
        let document = XHTMLRepair.prepare(data, path: normalized)
        contentDocuments[normalized] = document
        return document
    }

    /// Media type for a container path: the manifest value, else a guess from the extension.
    public nonisolated func mediaType(forPath path: String) -> String {
        publication.manifestItem(atPath: path)?.mediaType ?? MediaTypes.guess(forPath: path)
    }

    private nonisolated func shouldCache(path: String, size: Int) -> Bool {
        let type = mediaType(forPath: path)
        if type.hasPrefix("image/") || type.hasPrefix("font/") || type.hasPrefix("audio/") || type.hasPrefix("video/") { return false }
        if type == "application/vnd.ms-opentype" || type == "application/font-woff" || type.hasPrefix("application/x-font") { return false }
        return size <= 4 * 1024 * 1024
    }

    // MARK: - Loading

    struct Loaded {
        var archive: ZIPArchive
        var publication: Publication
        var obfuscations: [String: FontObfuscation] = [:]
        var unsupportedEncryptedPaths: Set<String> = []
        var contentDocuments: [String: ContentDocument] = [:]
    }

    enum Loader {
        static func load(url: URL) throws -> Loaded {
            let archive = try ZIPArchive(url: url)
            return try load(archive: archive)
        }

        static func load(data: Data, url: URL?) throws -> Loaded {
            let archive = try ZIPArchive(data: data, url: url)
            return try load(archive: archive)
        }

        static func load(archive: ZIPArchive) throws -> Loaded {
            var warnings: [PublicationWarning] = []

            // mimetype: must be the first entry, stored, with the exact content. Only a warning otherwise.
            let mimetypeOK: Bool = {
                guard let first = archive.firstEntry, first.path == "mimetype", first.method == 0,
                      let data = try? archive.data(for: first) else { return false }
                return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip"
            }()
            if !mimetypeOK { warnings.append(.missingMimetype) }

            guard archive.contains("META-INF/container.xml") else { throw EPUBError.missingContainerXML }
            let containerXML = try archive.data(at: "META-INF/container.xml")
            let opfPath = try PackageParser.packageDocumentPath(containerXML: containerXML)
            guard archive.contains(opfPath) else { throw EPUBError.missingPackageDocument(path: opfPath) }
            let opfData = try archive.data(at: opfPath)
            let parsed = try PackageParser.parse(opf: opfData, path: opfPath)
            warnings.append(contentsOf: parsed.warnings)

            // Resources referenced by the manifest that are not in the ZIP.
            for item in parsed.manifest where !archive.contains(item.path) && !item.properties.contains("remote-resources") {
                if item.href.contains(":") { continue } // remote URL
                warnings.append(.missingResource(path: item.path, referencedFrom: opfPath))
            }

            let spineByPath = Dictionary(parsed.readingOrder.map { ($0.path, $0.index) }, uniquingKeysWith: { first, _ in first })
            var toc: [TOCEntry] = []
            var pageList: [TOCEntry] = []
            var landmarks: [TOCEntry] = []
            var navParsed = false
            if let navPath = parsed.navigationDocumentPath, archive.contains(navPath),
               let navData = try? archive.data(at: navPath) {
                let prepared = XHTMLRepair.prepare(navData, path: navPath)
                warnings.append(contentsOf: prepared.warnings)
                if prepared.isXML, let document = try? XMLDocument(data: prepared.data) {
                    let result = NavigationParser.parse(document, navPath: navPath) { spineByPath[$0] }
                    toc = result.toc
                    pageList = result.pageList
                    landmarks = result.landmarks
                    navParsed = !toc.isEmpty
                }
            }
            if !navParsed {
                warnings.append(.missingNavigation)
                toc = NavigationParser.fallbackTOC(readingOrder: parsed.readingOrder)
            }

            // Spine documents: prepare them once (repair if needed) and count their text for the page-count estimate
            // (02-rendering §5.2). The prepared documents seed the container's cache so serving does not repeat the work.
            var contentDocuments: [String: ContentDocument] = [:]
            var readingOrder: [SpineItem] = []
            readingOrder.reserveCapacity(parsed.readingOrder.count)
            for item in parsed.readingOrder {
                var characterCount: Int?
                if item.mediaType == XHTMLRepair.xhtmlMediaType || item.path.hasSuffix(".xhtml") || item.path.hasSuffix(".html"),
                   archive.contains(item.path), let data = try? archive.data(at: item.path) {
                    let prepared = XHTMLRepair.prepareAndParse(data, path: item.path)
                    contentDocuments[item.path] = prepared.document
                    if let tree = prepared.tree { characterCount = TextLength.characterCount(of: tree) }
                }
                readingOrder.append(SpineItem(
                    id: item.id, index: item.index, path: item.path, mediaType: item.mediaType, isLinear: item.isLinear,
                    layout: item.layout, spreadPosition: item.spreadPosition, characterCount: characterCount
                ))
            }

            // META-INF/encryption.xml: font obfuscation is undone transparently by `data(at:)`; other
            // algorithms (DRM) are recorded as warnings and their resources cannot be read.
            var encryption = EncryptionParser.Result()
            if archive.contains("META-INF/encryption.xml"), let encryptionData = try? archive.data(at: "META-INF/encryption.xml") {
                encryption = EncryptionParser.parse(encryptionData, uniqueIdentifier: parsed.metadata.identifier)
                warnings.append(contentsOf: encryption.warnings)
            }

            let publication = Publication(
                id: PublicationID(),
                metadata: parsed.metadata,
                manifest: parsed.manifest,
                readingOrder: readingOrder,
                toc: toc,
                pageList: pageList,
                landmarks: landmarks,
                layout: parsed.layout,
                spread: parsed.spread,
                pageProgression: parsed.pageProgression,
                coverImagePath: parsed.coverImagePath,
                packageDocumentPath: opfPath,
                navigationDocumentPath: parsed.navigationDocumentPath,
                warnings: warnings
            )
            return Loaded(
                archive: archive,
                publication: publication,
                obfuscations: encryption.obfuscations,
                unsupportedEncryptedPaths: encryption.unsupported,
                contentDocuments: contentDocuments
            )
        }
    }
}
