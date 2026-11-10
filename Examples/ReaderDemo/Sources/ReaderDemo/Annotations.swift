import SwiftUI
import CryptoKit
import EPUB

/// What the demo keeps per book between launches: the annotations (highlights and bookmarks) and the last reading
/// position (docs/design/04-roadmap.md M3 / M6). The annotations are an `AnnotationSet` in the library's storage form
/// (`<hash>.annotations.json`); the position is in `<hash>.json`. Both live in Application Support.
@MainActor
@Observable
final class BookStore {
    struct Contents: Codable {
        var position: ReadingPosition?
        /// Highlights saved before M6 (`Highlight` was removed). Read once, converted, and not written again.
        var highlights: [LegacyHighlight]?
    }

    let url: URL
    let annotationsURL: URL
    /// The set's id stays the same across launches, so an export of it is recognized when imported again.
    private(set) var setID: String
    var annotations: [Annotation] {
        didSet { saveAnnotations() }
    }
    var position: ReadingPosition? {
        didSet { save() }
    }

    init(bookID: String, publication: Publication) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("ReaderDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A hash of the id, so that ids differing only in punctuation (`A-B.epub`, `A_B.epub`) get separate files.
        let name = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        url = directory.appendingPathComponent("\(name).json")
        annotationsURL = directory.appendingPathComponent("\(name).annotations.json")
        Self.migrateLegacyFile(bookID: bookID, in: directory, to: url)
        let contents = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
        position = contents.position
        if let data = try? Data(contentsOf: annotationsURL), let (set, _) = try? AnnotationCodec.decode(data) {
            setID = set.id
            annotations = set.items
        } else {
            setID = AnnotationSet.newID()
            annotations = (contents.highlights ?? []).map { $0.annotation(in: publication) }
        }
        if contents.highlights != nil {
            // Converted: write the annotations file and drop the old list.
            saveAnnotations()
            save()
        }
    }

    /// The set as exported: this book's description, the store's id and the annotations.
    func annotationSet(about publication: Publication) -> AnnotationSet {
        AnnotationSet(id: setID, about: AnnotationSet.About(publication: publication), items: annotations)
    }

    /// Earlier versions named the file after the book id with every non-alphanumeric character replaced by `_`
    /// (`moby-dick` → `moby_dick.json`). The first book to open with such a file takes it over (moved, not copied:
    /// ids that differ only in punctuation shared that file, and the contents should not appear under two books).
    static func migrateLegacyFile(bookID: String, in directory: URL, to url: URL) {
        let fileManager = FileManager.default
        let legacyName = bookID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        let legacy = directory.appendingPathComponent("\(legacyName).json")
        guard legacy != url, !fileManager.fileExists(atPath: url.path), fileManager.fileExists(atPath: legacy.path) else { return }
        try? fileManager.moveItem(at: legacy, to: url)
    }

    private func save() {
        let contents = Contents(position: position)
        guard let data = try? JSONEncoder().encode(contents) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func saveAnnotations() {
        let set = AnnotationSet(id: setID, items: annotations)
        guard let data = try? AnnotationCodec.encode(set, mode: .storage) else { return }
        try? data.write(to: annotationsURL, options: .atomic)
    }
}

/// The `Highlight` JSON the demo saved before M6: `{id, range, style: {background|underline: {_0: color}}, note}`.
struct LegacyHighlight: Codable {
    enum Style: Codable {
        case background(ReaderColor)
        case underline(ReaderColor)
    }

    var id: UUID
    var range: CFIRange
    var style: Style
    /// The demo put the selected text here, not a note of the reader's; it is not carried over (the export's
    /// TextQuoteSelector holds the text).
    var note: String?

    /// The highlight as an annotation: same id (as a `urn:uuid:`), the nearest color label, solid or underline.
    func annotation(in publication: Publication) -> Annotation {
        let color: ReaderColor
        let style: HighlightStyle
        switch self.style {
        case .background(let c): color = c; style = .solid
        case .underline(let c): color = c; style = .underline
        }
        var annotation = Annotation.highlight(range, in: publication, color: Self.nearestLabel(to: color), style: style)
        annotation.id = "urn:uuid:" + id.uuidString.lowercased()
        return annotation
    }

    /// The label whose light-theme color is nearest in RGB.
    static func nearestLabel(to color: ReaderColor) -> HighlightColor {
        func distance(_ a: ReaderColor, _ b: ReaderColor) -> Double {
            let dr = a.red - b.red, dg = a.green - b.green, db = a.blue - b.blue
            return dr * dr + dg * dg + db * db
        }
        return HighlightColor.standard.min { distance(ReaderTheme.lightPalette[$0]!, color) < distance(ReaderTheme.lightPalette[$1]!, color) } ?? .yellow
    }
}

extension Annotation {
    /// Sets the color label and the style, keeping the note and the tags.
    func with(color: HighlightColor? = nil, style: HighlightStyle? = nil) -> Annotation {
        var copy = self
        var body = copy.body ?? Body()
        if let color { body.color = color }
        if let style { body.style = style }
        copy.body = body
        copy.modified = Annotation.now()
        return copy
    }
}

extension HighlightColor {
    var title: String { rawValue.capitalized }
}

extension HighlightStyle {
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .solid: "highlighter"
        case .underline: "underline"
        case .strikethrough: "strikethrough"
        case .outline: "rectangle.dashed"
        case .other: "questionmark"
        }
    }
}

/// Saved annotations: highlights and bookmarks. Tap to jump, swipe to delete. The quoted text comes from the
/// TextQuoteSelector the library generates for each highlight.
struct AnnotationsView: View {
    let session: ReaderSession
    let store: BookStore
    let onSelect: () -> Void

    @State private var quotes: [Annotation.ID: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if store.annotations.isEmpty && session.publicationAnnotations.isEmpty {
                    ContentUnavailableView("No annotations", systemImage: "highlighter", description: Text("Select text and choose Highlight, or add a bookmark."))
                } else {
                    List {
                        Section("Mine") {
                            ForEach(store.annotations, id: \.id) { annotation in
                                row(annotation)
                            }
                            .onDelete { offsets in
                                store.annotations.remove(atOffsets: offsets)
                            }
                        }
                        if !session.publicationAnnotations.isEmpty {
                            Section {
                                Toggle("Show the publisher's annotations", isOn: Binding(get: { session.showsPublicationAnnotations }, set: { session.showsPublicationAnnotations = $0 }))
                                ForEach(session.publicationAnnotations, id: \.id) { annotation in
                                    row(annotation)
                                }
                            } header: {
                                Text("From the publication")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Annotations")
            .toolbar {
                Button("Done") { onSelect() }
            }
            .task(id: store.annotations.map(\.id) + session.publicationAnnotations.map(\.id)) {
                let all = store.annotations + session.publicationAnnotations
                let generated = await AnnotationResolver(container: session.container).generatingSelectors(for: all)
                var out: [Annotation.ID: String] = [:]
                for annotation in generated {
                    for selector in annotation.target.generatedSelectors ?? [] {
                        if case .textQuote(let exact, _, _) = selector { out[annotation.id] = exact }
                    }
                }
                quotes = out
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func row(_ annotation: Annotation) -> some View {
        Button {
            if let cfi = annotation.startCFI { Task { await session.go(to: cfi) } }
            onSelect()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if annotation.motivation == .bookmarking {
                    Image(systemName: "bookmark.fill").foregroundStyle(.secondary).frame(width: 6)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(session.settings.theme.color(for: annotation.color)))
                        .frame(width: 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(quotes[annotation.id] ?? (annotation.motivation == .bookmarking ? "Bookmark" : "…"))
                        .lineLimit(3)
                    if let note = annotation.note, !note.text.isEmpty {
                        Text(note.text).italic().lineLimit(2)
                    }
                    Text([chapterTitle(for: annotation), annotation.motivation == .highlighting ? annotation.style.title : nil, origin(annotation)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(annotation.startCFI?.description ?? "unresolved")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func origin(_ annotation: Annotation) -> String? {
        switch annotation.origin {
        case .local: nil
        case .imported: "imported"
        case .publication: "publisher"
        }
    }

    private func chapterTitle(for annotation: Annotation) -> String? {
        guard let cfi = annotation.startCFI, let spineIndex = session.publication.spineIndex(of: cfi) else { return nil }
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

/// A tapped highlight: color label, style, note, delete.
struct AnnotationEditor: View {
    let annotation: Annotation
    let session: ReaderSession
    let isEditable: Bool
    let onChange: (Annotation) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Color") {
                    HStack(spacing: 12) {
                        ForEach(HighlightColor.standard, id: \.self) { color in
                            Button {
                                onChange(annotation.with(color: color))
                            } label: {
                                Circle()
                                    .fill(Color(session.settings.theme.color(for: color)))
                                    .frame(width: 28, height: 28)
                                    .overlay { if annotation.color == color { Image(systemName: "checkmark").font(.caption.bold()) } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.title)
                        }
                    }
                    .disabled(!isEditable)
                }
                Section("Style") {
                    Picker("Style", selection: Binding(get: { annotation.style }, set: { onChange(annotation.with(style: $0)) })) {
                        ForEach(HighlightStyle.standard, id: \.self) { style in
                            Label(style.title, systemImage: style.systemImage).tag(style)
                        }
                    }
                    .disabled(!isEditable)
                }
                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .disabled(!isEditable)
                        .onSubmit(saveNote)
                }
                if isEditable {
                    Button("Delete", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                } else {
                    Text("This annotation comes with the publication and cannot be changed.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Highlight")
            .toolbar {
                Button("Done") {
                    saveNote()
                    dismiss()
                }
            }
            .onAppear { note = annotation.note?.text ?? "" }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #else
        .presentationDetents([.medium])
        #endif
    }

    private func saveNote() {
        guard isEditable, note != (annotation.note?.text ?? "") else { return }
        var copy = annotation
        copy.note = note.isEmpty ? nil : LocalizableText(note)
        copy.modified = Annotation.now()
        onChange(copy)
    }
}

/// Full-text search: results stream in as chapters are searched; tapping one shows it with a transient highlight.
struct SearchView: View {
    let session: ReaderSession
    let onSelect: () -> Void

    @State private var query = ""
    @State private var submittedQuery = ""
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
            // On macOS, `.onSubmit(of: .search)` does not fire for a `.searchable` field inside this sheet, so the
            // search also starts once typing pauses (both platforms; Return still searches at once on iOS).
            .task(id: query) {
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, submittedQuery != query else { return }
                search()
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
        submittedQuery = query
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
