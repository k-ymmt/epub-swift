import Foundation

/// Parses the EPUB 3 navigation document (docs/design/01-core.md §2.3).
enum NavigationParser {
    struct Result {
        var toc: [TOCEntry] = []
        var pageList: [TOCEntry] = []
        var landmarks: [TOCEntry] = []
    }

    /// `navPath` is the container path of the nav document; hrefs resolve against it.
    static func parse(_ document: XMLDocument, navPath: String, spineIndexForPath: (String) -> Int?) -> Result {
        var result = Result()
        let navs = document.root.descendants { $0.name == "nav" }
        for nav in navs {
            let types = Set(epubType(of: nav).split(separator: " ").map(String.init))
            guard let list = nav.firstChild(named: "ol") else { continue }
            let entries = parseList(list, navPath: navPath, depth: 0, spineIndexForPath: spineIndexForPath)
            if types.contains("toc"), result.toc.isEmpty {
                result.toc = entries
            } else if types.contains("page-list"), result.pageList.isEmpty {
                result.pageList = entries
            } else if types.contains("landmarks"), result.landmarks.isEmpty {
                result.landmarks = entries
            }
        }
        return result
    }

    /// Flat table of contents from the spine, used when there is no usable nav document.
    static func fallbackTOC(readingOrder: [SpineItem]) -> [TOCEntry] {
        readingOrder.filter(\.isLinear).map { item in
            TOCEntry(
                label: (item.path as NSString).lastPathComponent,
                href: item.path,
                spineIndex: item.index,
                fragment: nil,
                children: [],
                depthToken: "fallback-\(item.index)"
            )
        }
    }

    private static func epubType(of element: XMLElement) -> String {
        element.attribute("type", namespace: XMLNamespace.epub)
            ?? element.attributes.first { $0.name == "type" && $0.prefix == "epub" }?.value
            ?? ""
    }

    private static func parseList(_ list: XMLElement, navPath: String, depth: Int, spineIndexForPath: (String) -> Int?) -> [TOCEntry] {
        var entries: [TOCEntry] = []
        for (index, li) in list.childElements(named: "li").enumerated() {
            // Label: the first <a> or <span> child. Nested <ol> gives children.
            var label = ""
            var href: String?
            var spineIndex: Int?
            var fragment: String?
            var children: [TOCEntry] = []
            for child in li.childElements {
                switch child.name {
                case "a":
                    if label.isEmpty { label = collapseWhitespace(child.textContent) }
                    if href == nil, let raw = child.attribute("href") {
                        let (_, frag) = ContainerPath.splitFragment(raw)
                        if let resolved = ContainerPath.resolve(href: raw, relativeTo: navPath) {
                            href = resolved
                            fragment = frag
                            spineIndex = spineIndexForPath(resolved)
                        } else {
                            href = raw
                            fragment = frag
                        }
                    }
                case "span":
                    if label.isEmpty { label = collapseWhitespace(child.textContent) }
                case "ol":
                    children = parseList(child, navPath: navPath, depth: depth + 1, spineIndexForPath: spineIndexForPath)
                default:
                    if label.isEmpty { label = collapseWhitespace(child.textContent) }
                }
            }
            if label.isEmpty, href == nil, children.isEmpty { continue }
            entries.append(TOCEntry(
                label: label,
                href: href,
                spineIndex: spineIndex,
                fragment: fragment,
                children: children,
                depthToken: "\(depth)-\(index)"
            ))
        }
        return entries
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
