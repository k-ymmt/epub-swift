import Foundation
import WebKit
import libxml2

/// CFI-style canonical dump of a DOM: element steps are even (2, 4, ...), text chunks odd (1, 3, ...).
/// Comments / PIs are folded into the surrounding text chunk as empty text, adjacent text nodes are merged.
let domDumpJS = """
    function esc(s) { return s.replace(/\\\\/g, "\\\\\\\\").replace(/\\n/g, "\\\\n").replace(/\\u00a0/g, "[nbsp]"); }
    function dump(node, path, out) {
      let elemIdx = 0; let chunk = null;
      const flush = () => { if (chunk !== null && chunk.length > 0) out.push(path + "/" + (2 * elemIdx + 1) + ' "' + esc(chunk) + '"'); chunk = null; };
      for (const c of node.childNodes) {
        if (c.nodeType === 1) {
          flush(); elemIdx++;
          const p = path + "/" + (2 * elemIdx);
          out.push(p + " " + c.localName + (c.id ? "#" + c.id : ""));
          dump(c, p, out);
        } else if (c.nodeType === 3 || c.nodeType === 4) {
          chunk = (chunk ?? "") + c.data;
        } else {
          chunk = chunk ?? "";
        }
      }
      flush();
    }
    const out = [];
    dump(document.documentElement, "", out);
    return { lines: out, contentType: document.contentType, compatMode: document.compatMode };
    """

private func xmlString(_ p: UnsafePointer<xmlChar>?) -> String {
    guard let p else { return "" }
    return p.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
}

private func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\u{00a0}", with: "[nbsp]")
}

private func dumpLibxml(_ node: xmlNodePtr, _ path: String, _ out: inout [String]) {
    var elemIdx = 0
    var chunk: String? = nil
    func flush() {
        if let c = chunk, !c.isEmpty { out.append("\(path)/\(2 * elemIdx + 1) \"\(esc(c))\"") }
        chunk = nil
    }
    var cur = node.pointee.children
    while let c = cur {
        switch c.pointee.type {
        case XML_ELEMENT_NODE:
            flush()
            elemIdx += 1
            let p = "\(path)/\(2 * elemIdx)"
            let name = xmlString(c.pointee.name)
            var id = ""
            if let prop = xmlGetProp(c, "id") {
                id = "#" + xmlString(prop)
                free(prop)
            }
            out.append("\(p) \(name)\(id)")
            dumpLibxml(c, p, &out)
        case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
            chunk = (chunk ?? "") + xmlString(c.pointee.content)
        default:
            chunk = chunk ?? ""
        }
        cur = c.pointee.next
    }
    flush()
}

public func libxmlHTMLDump(_ source: String) -> [String] {
    let opts = Int32(HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NONET.rawValue)
    guard let doc = source.withCString({ htmlReadMemory($0, Int32(strlen($0)), "doc.html", "UTF-8", opts) }) else { return ["<parse failed>"] }
    defer { xmlFreeDoc(doc) }
    guard let root = xmlDocGetRootElement(doc) else { return ["<no root>"] }
    var out: [String] = []
    dumpLibxml(root, "", &out)
    return out
}

/// Lenient view: element lines only plus text chunks with whitespace collapsed (whitespace-only chunks dropped).
func lenient(_ lines: [String]) -> [String] {
    lines.compactMap { line in
        guard let q = line.firstIndex(of: "\"") else { return line }
        let text = line[q...].replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\"", with: "")
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if collapsed.isEmpty { return nil }
        return String(line[..<q]) + "\"" + collapsed + "\""
    }
}

func diffLines(_ a: [String], _ b: [String]) -> (onlyA: [String], onlyB: [String]) {
    let sa = Set(a), sb = Set(b)
    return (a.filter { !sb.contains($0) }, b.filter { !sa.contains($0) })
}

/// 5. XML-broken XHTML served as text/html: WebKit's HTML5 DOM vs libxml2 (2.9.x) HTML parser DOM.
@MainActor
public func runSpike5(_ ctx: SpikeContext) async -> SpikeResult {
    var r = SpikeResult(id: 5, title: "壊れた XHTML の text/html 配信: WebKit DOM と libxml2 HTML パーサ DOM の CFI インデックス一致")
    r.note("libxml2 runtime version: \(String(cString: __xmlParserVersion().pointee!)) (compile-time \(LIBXML_DOTTED_VERSION))")
    do {
        let host = WebHost(visibleSize: CGSize(width: 300, height: 400))
        var allStrictEqual = true
        var allLenientEqual = true
        for doc in Fixtures.brokenDocs {
            host.serve("/\(doc.name).xhtml", Fixtures.htmlMIME, doc.source)
            try await host.load("/\(doc.name).xhtml")
            let wk = try await host.jsDict(domDumpJS)
            let wkLines = wk["lines"] as? [String] ?? []
            let lxLines = libxmlHTMLDump(doc.source)
            try (wkLines.joined(separator: "\n") + "\n").write(to: ctx.outputDirectory.appendingPathComponent("spike5-\(doc.name)-webkit.txt"), atomically: true, encoding: .utf8)
            try (lxLines.joined(separator: "\n") + "\n").write(to: ctx.outputDirectory.appendingPathComponent("spike5-\(doc.name)-libxml2.txt"), atomically: true, encoding: .utf8)
            let strict = diffLines(wkLines, lxLines)
            let len = diffLines(lenient(wkLines), lenient(lxLines))
            let strictEqual = strict.onlyA.isEmpty && strict.onlyB.isEmpty
            let lenientEqual = len.onlyA.isEmpty && len.onlyB.isEmpty
            allStrictEqual = allStrictEqual && strictEqual
            allLenientEqual = allLenientEqual && lenientEqual
            r.note("[\(doc.name)] WebKit contentType=\(wk["contentType"] ?? "?") ノード行数 WebKit=\(wkLines.count) libxml2=\(lxLines.count) 厳密一致=\(strictEqual) 空白無視一致=\(lenientEqual)")
            for l in len.onlyA.prefix(12) { r.note("    WebKit のみ: \(l)") }
            for l in len.onlyB.prefix(12) { r.note("    libxml2 のみ: \(l)") }
            if lenientEqual && !strictEqual {
                for l in strict.onlyA.prefix(4) { r.note("    (空白差) WebKit のみ: \(l)") }
                for l in strict.onlyB.prefix(4) { r.note("    (空白差) libxml2 のみ: \(l)") }
            }
        }
        // Control: the same documents parsed by WebKit as XML would be error pages; confirm one.
        host.serve("/asxml.xhtml", Fixtures.xhtmlMIME, Fixtures.brokenDocs[1].source)
        try await host.load("/asxml.xhtml")
        let asXML = try await host.jsDict("return { contentType: document.contentType, hasParserError: !!document.querySelector('parsererror'), title: document.title, bodyStart: (document.body ? document.body.textContent.trim().slice(0, 60) : null) }")
        r.note("対照: 同じ文書を application/xhtml+xml で配信 → \(asXML)")
        r.verdict = allStrictEqual ? .pass : (allLenientEqual ? .conditional : .fail)
        r.note("判定根拠: 全文書で厳密一致=\(allStrictEqual) 空白無視一致=\(allLenientEqual)。ダンプは Spikes/output/spike5-*.txt")
    } catch {
        r.error = "\(error)"; r.verdict = .fail
    }
    return r
}
