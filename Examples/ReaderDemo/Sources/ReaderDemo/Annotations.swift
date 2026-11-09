import SwiftUI
import EPUB

/// What the demo keeps per book between launches: the highlights and the last reading position, as a JSON file in
/// Application Support (docs/design/04-roadmap.md M3: "ハイライトを保存して再起動後に同じ位置に出る").
@MainActor
@Observable
final class BookStore {
    struct Contents: Codable {
        var highlights: [Highlight] = []
        var position: ReadingPosition?
    }

    let url: URL
    var highlights: [Highlight] {
        didSet { save() }
    }
    var position: ReadingPosition? {
        didSet { save() }
    }

    init(bookID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("ReaderDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = bookID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        url = directory.appendingPathComponent("\(name).json")
        let contents = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
        highlights = contents.highlights
        position = contents.position
    }

    private func save() {
        let contents = Contents(highlights: highlights, position: position)
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Saved highlights: tap to jump, swipe to delete. The note holds the selected text at the time of creation.
struct HighlightsView: View {
    let session: ReaderSession
    let store: BookStore
    let onSelect: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.highlights.isEmpty {
                    ContentUnavailableView("No highlights", systemImage: "highlighter", description: Text("Select text and choose Highlight."))
                } else {
                    List {
                        ForEach(store.highlights) { highlight in
                            Button {
                                Task { await session.go(to: highlight.range.start) }
                                onSelect()
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(highlight.style.color))
                                        .frame(width: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(highlight.note ?? "(no text)")
                                            .lineLimit(3)
                                        Text(chapterTitle(for: highlight) ?? "Chapter \(highlight.spineIndex + 1)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(highlight.range.description)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            store.highlights.remove(atOffsets: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Highlights")
            .toolbar {
                Button("Done") { onSelect() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func chapterTitle(for highlight: Highlight) -> String? {
        guard let spineIndex = session.publication.spineIndex(of: highlight.range.start) else { return nil }
        func search(_ entries: [TOCEntry]) -> String? {
            var found: String?
            for entry in entries {
                if entry.spineIndex == spineIndex { found = entry.label }
                if let nested = search(entry.children) { found = nested }
            }
            return found
        }
        return search(session.publication.toc)
    }
}

/// Full-text search: results stream in as chapters are searched; tapping one shows it with a transient highlight.
struct SearchView: View {
    let session: ReaderSession
    let onSelect: () -> Void

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(results) { result in
                    Button {
                        Task { await session.show(result) }
                        onSelect()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            snippet(result)
                                .lineLimit(3)
                            Text(chapterLabel(result.spineIndex))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if results.isEmpty, !isSearching, !query.isEmpty, error == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .automatic, prompt: "Search the book")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty { searchTask?.cancel(); results = [] }
            }
            .navigationTitle(isSearching ? "Searching… (\(results.count))" : "Search (\(results.count))")
            .toolbar {
                Button("Done") { searchTask?.cancel(); onSelect() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }

    private func search() {
        searchTask?.cancel()
        results = []
        error = nil
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchTask = Task {
            defer { isSearching = false }
            do {
                for try await result in session.search(trimmed) {
                    if Task.isCancelled { return }
                    results.append(result)
                }
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    private func snippet(_ result: SearchResult) -> Text {
        let snippet = result.snippet
        let range = result.matchRangeInSnippet
        let before = Text(snippet[..<range.lowerBound])
        let match = Text(snippet[range]).bold().foregroundStyle(.orange)
        let after = Text(snippet[range.upperBound...])
        return Text("\(before)\(match)\(after)")
    }

    private func chapterLabel(_ spineIndex: Int) -> String {
        func search(_ entries: [TOCEntry]) -> String? {
            var found: String?
            for entry in entries {
                if entry.spineIndex == spineIndex { found = entry.label }
                if let nested = search(entry.children) { found = nested }
            }
            return found
        }
        return search(session.publication.toc) ?? "Chapter \(spineIndex + 1)"
    }
}
