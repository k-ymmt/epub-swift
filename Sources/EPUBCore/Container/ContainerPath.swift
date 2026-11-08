import Foundation

/// Path handling for ZIP entry names and OPF/nav hrefs (docs/design/01-core.md §1.1).
///
/// Container paths are stored normalized: UTF-8, `/` separated, no leading `/`, no `.` or empty segments,
/// `..` resolved, percent-decoded.
public enum ContainerPath {
    public static func normalize(_ path: String) -> String {
        var segments: [Substring] = []
        for seg in path.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." {
                if !segments.isEmpty { segments.removeLast() }
                continue
            }
            segments.append(seg)
        }
        return segments.joined(separator: "/")
    }

    /// Directory of a container path (`OPS/package.opf` → `OPS`, `package.opf` → ``).
    public static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Splits an href into its path and fragment parts (`a.xhtml#x` → (`a.xhtml`, `x`)).
    public static func splitFragment(_ href: String) -> (path: String, fragment: String?) {
        guard let hash = href.firstIndex(of: "#") else { return (href, nil) }
        let fragment = String(href[href.index(after: hash)...])
        return (String(href[..<hash]), fragment.isEmpty ? nil : fragment)
    }

    /// Resolves an href (as written in an OPF or XHTML document) against the directory of the referring document
    /// and returns the normalized, percent-decoded container path. Returns nil for absolute URLs (`http:`, `data:`...).
    public static func resolve(href: String, relativeTo documentPath: String) -> String? {
        let (rawPath, _) = splitFragment(href)
        if rawPath.isEmpty { return normalize(documentPath) }
        if let colon = rawPath.firstIndex(of: ":"), !rawPath[..<colon].contains("/") {
            // scheme:... → absolute URL, not a container path
            return nil
        }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        if decoded.hasPrefix("/") { return normalize(decoded) }
        let dir = directory(of: documentPath)
        return normalize(dir.isEmpty ? decoded : dir + "/" + decoded)
    }

    /// Percent-encodes a container path for use in an `epub://` URL path.
    public static func percentEncoded(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowedStrict) ?? String($0) }
            .joined(separator: "/")
    }
}

extension CharacterSet {
    /// `urlPathAllowed` minus the characters that would be misread inside a single path segment.
    static let urlPathAllowedStrict: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/;?#%")
        return set
    }()
}
