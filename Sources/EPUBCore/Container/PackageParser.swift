import Foundation

/// Parses `META-INF/container.xml` and the OPF package document (docs/design/01-core.md §2.1, §2.2).
enum PackageParser {
    /// Returns the container path of the first `rootfile` with the OPF media type.
    static func packageDocumentPath(containerXML data: Data) throws -> String {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data)
        } catch {
            throw EPUBError.invalidPackage("container.xml is not well-formed: \(error)")
        }
        let rootfiles = document.root.descendants { $0.name == "rootfile" }
        let opf = rootfiles.first { $0.attribute("media-type") == "application/oebps-package+xml" } ?? rootfiles.first
        guard let fullPath = opf?.attribute("full-path"), !fullPath.isEmpty else {
            throw EPUBError.invalidPackage("container.xml has no rootfile")
        }
        return ContainerPath.normalize(fullPath.removingPercentEncoding ?? fullPath)
    }

    struct ParsedPackage {
        var metadata: Metadata
        var manifest: [ManifestItem]
        var readingOrder: [SpineItem]
        var layout: RenditionLayout
        var spread: RenditionSpread
        var pageProgression: PageProgression
        var coverImagePath: String?
        var navigationDocumentPath: String?
        /// CFI step of the `spine` element among `package`'s element children.
        var spineElementIndex: Int
        var warnings: [PublicationWarning]
    }

    static func parse(opf data: Data, path opfPath: String) throws -> ParsedPackage {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: data)
        } catch {
            throw EPUBError.invalidPackage("package document is not well-formed: \(error)")
        }
        let package = document.root
        guard package.name == "package" else {
            throw EPUBError.invalidPackage("root element is <\(package.qualifiedName)>, expected <package>")
        }
        var warnings: [PublicationWarning] = []

        // --- metadata ---------------------------------------------------------------------------
        let uniqueIdentifierID = package.attribute("unique-identifier")
        var metadata = Metadata()
        var raw: [String: [String]] = [:]
        var refinements: [String: [(property: String, value: String)]] = [:]
        var titles: [(id: String?, value: String)] = []
        var identifiers: [(id: String?, value: String)] = []
        var creators: [(id: String?, value: String)] = []
        if let metadataElement = package.firstChild(named: "metadata") {
            for child in metadataElement.childElements {
                let text = child.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if child.namespaceURI == XMLNamespace.dc || child.prefix == "dc" {
                    raw["dc:\(child.name)", default: []].append(text)
                    switch child.name {
                    case "title": titles.append((child.id, text))
                    case "identifier": identifiers.append((child.id, text))
                    case "creator": creators.append((child.id, text))
                    case "language": if metadata.language == nil { metadata.language = text }
                    case "publisher": if metadata.publisher == nil { metadata.publisher = text }
                    default: break
                    }
                } else if child.name == "meta" {
                    if let property = child.attribute("property") {
                        if let refines = child.attribute("refines") {
                            let target = refines.hasPrefix("#") ? String(refines.dropFirst()) : refines
                            refinements[target, default: []].append((property, text))
                        } else {
                            raw[property, default: []].append(text)
                        }
                    }
                    // OPF 2 style <meta name content> is intentionally not read (EPUB 3 only).
                }
            }
        }
        if let main = titles.first(where: { t in t.id.flatMap { refinements[$0] }?.contains { $0.property == "title-type" && $0.value == "main" } ?? false }) {
            metadata.title = main.value
            metadata.alternativeTitles = titles.filter { $0.value != main.value || $0.id != main.id }.map(\.value)
        } else if let first = titles.first {
            metadata.title = first.value
            metadata.alternativeTitles = titles.dropFirst().map(\.value)
        }
        metadata.authors = creators.map(\.value)
        if let uid = uniqueIdentifierID, let match = identifiers.first(where: { $0.id == uid }) {
            metadata.identifier = match.value
        } else {
            metadata.identifier = identifiers.first?.value
        }
        if let modified = raw["dcterms:modified"]?.first {
            metadata.modified = parseDate(modified)
        }
        metadata.rawMetadata = raw

        let layout: RenditionLayout = raw["rendition:layout"]?.first.flatMap(RenditionLayout.init(rawValue:)) ?? .reflowable
        let spread: RenditionSpread = raw["rendition:spread"]?.first.flatMap(RenditionSpread.init(rawValue:)) ?? .auto

        // --- manifest ---------------------------------------------------------------------------
        var manifest: [ManifestItem] = []
        var seenIDs: Set<String> = []
        var coverImagePath: String?
        var navigationDocumentPath: String?
        if let manifestElement = package.firstChild(named: "manifest") {
            for item in manifestElement.childElements(named: "item") {
                guard let id = item.attribute("id"), let href = item.attribute("href") else { continue }
                if !seenIDs.insert(id).inserted {
                    warnings.append(.duplicateManifestID(id: id))
                    continue
                }
                let resolvedPath = ContainerPath.resolve(href: href, relativeTo: opfPath) ?? href
                var mediaType = item.attribute("media-type") ?? ""
                if mediaType.isEmpty {
                    warnings.append(.unknownMediaType(path: resolvedPath))
                    mediaType = MediaTypes.guess(forPath: resolvedPath)
                }
                let properties = Set((item.attribute("properties") ?? "").split(separator: " ").map(String.init))
                let manifestItem = ManifestItem(
                    id: id,
                    href: href,
                    path: resolvedPath,
                    mediaType: mediaType,
                    properties: properties,
                    fallback: item.attribute("fallback"),
                    mediaOverlay: item.attribute("media-overlay")
                )
                manifest.append(manifestItem)
                if manifestItem.isCoverImage, coverImagePath == nil { coverImagePath = resolvedPath }
                if manifestItem.isNavigation, navigationDocumentPath == nil { navigationDocumentPath = resolvedPath }
            }
        }
        let manifestByID = Dictionary(manifest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // --- spine ------------------------------------------------------------------------------
        var readingOrder: [SpineItem] = []
        var pageProgression: PageProgression = .default
        guard let spineElement = package.firstChild(named: "spine") else {
            throw EPUBError.invalidPackage("package document has no <spine>")
        }
        if let ppd = spineElement.attribute("page-progression-direction"), let value = PageProgression(rawValue: ppd) {
            pageProgression = value
        }
        let spineElementIndex = 2 * ((package.childElements.firstIndex { $0.name == "spine" } ?? 2) + 1)
        for (childPosition, itemref) in spineElement.childElements.enumerated() {
            // Every element child counts for the CFI step, even one that is not an itemref.
            guard itemref.name == "itemref" else { continue }
            guard let idref = itemref.attribute("idref") else { continue }
            guard let item = manifestByID[idref] else {
                warnings.append(.missingResource(path: idref, referencedFrom: opfPath))
                continue
            }
            let properties = Set((itemref.attribute("properties") ?? "").split(separator: " ").map(String.init))
            var itemLayout = layout
            if properties.contains("rendition:layout-pre-paginated") { itemLayout = .prePaginated }
            if properties.contains("rendition:layout-reflowable") { itemLayout = .reflowable }
            var spreadPosition: SpreadPosition?
            if properties.contains("page-spread-left") || properties.contains("rendition:page-spread-left") { spreadPosition = .left }
            if properties.contains("page-spread-right") || properties.contains("rendition:page-spread-right") { spreadPosition = .right }
            if properties.contains("rendition:page-spread-center") || properties.contains("page-spread-center") { spreadPosition = .center }
            readingOrder.append(SpineItem(
                id: idref,
                index: readingOrder.count,
                path: item.path,
                mediaType: item.mediaType,
                isLinear: itemref.attribute("linear")?.lowercased() != "no",
                layout: itemLayout,
                spreadPosition: spreadPosition,
                cfiStepIndex: 2 * (childPosition + 1)
            ))
        }
        if readingOrder.isEmpty {
            throw EPUBError.invalidPackage("spine has no resolvable itemref")
        }

        return ParsedPackage(
            metadata: metadata,
            manifest: manifest,
            readingOrder: readingOrder,
            layout: layout,
            spread: spread,
            pageProgression: pageProgression,
            coverImagePath: coverImagePath,
            navigationDocumentPath: navigationDocumentPath,
            spineElementIndex: spineElementIndex,
            warnings: warnings
        )
    }

    private static func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withFullDate]
        return iso.date(from: string)
    }
}

/// Media type guesses from file extensions, used when the manifest omits `media-type` and for `_reader/` resources.
public enum MediaTypes {
    public static func guess(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "xhtml", "xht", "html", "htm": return "application/xhtml+xml"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "otf": return "font/otf"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "opf": return "application/oebps-package+xml"
        case "ncx": return "application/x-dtbncx+xml"
        case "xml": return "application/xml"
        case "mp3": return "audio/mpeg"
        case "mp4", "m4v": return "video/mp4"
        case "json": return "application/json"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}
