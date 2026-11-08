import Foundation

public enum Verdict: String, Sendable {
    case pass = "成立"
    case fail = "不成立"
    case conditional = "条件付き"
    case notRun = "未実行"
}

public struct SpikeResult: Sendable {
    public var id: Int
    public var title: String
    public var verdict: Verdict
    public var notes: [String] = []
    public var error: String?

    public init(id: Int, title: String, verdict: Verdict = .notRun) {
        self.id = id
        self.title = title
        self.verdict = verdict
    }

    public mutating func note(_ line: String) {
        notes.append(line)
        print("  [\(id)] \(line)")
    }

    public var rendered: String {
        var out = "## Spike \(id): \(title)\n判定: \(verdict.rawValue)\n"
        for n in notes { out += "- \(n)\n" }
        if let error { out += "- ERROR: \(error)\n" }
        return out
    }
}

public struct SpikeContext: Sendable {
    public var outputDirectory: URL
    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }
}

public enum SpikeError: Error, CustomStringConvertible {
    case timeout(String)
    case unexpected(String)
    public var description: String {
        switch self {
        case .timeout(let s): return "timeout: \(s)"
        case .unexpected(let s): return "unexpected: \(s)"
        }
    }
}

public func fmt(_ v: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", v)
}
