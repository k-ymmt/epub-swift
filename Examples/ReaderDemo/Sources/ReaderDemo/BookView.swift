import SwiftUI
import EPUB

/// One open book: the reader view, a status bar, and sheets for the table of contents and the settings.
struct BookView: View {
    let book: Book

    @State private var session: ReaderSession?
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var status = ""
    @State private var readThrough: ReadThroughResult?
    @State private var showGoToPage = false
    @State private var goToPageText = ""

    var body: some View {
        Group {
            if let session {
                reader(session)
            } else if let loadError {
                ContentUnavailableView("Could not open", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                ProgressView("Opening \(book.title)…")
            }
        }
        .navigationTitle(session?.publication.metadata.title ?? book.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup {
                Button("Contents", systemImage: "list.bullet") { showTOC = true }
                    .disabled(session == nil)
                Button("Settings", systemImage: "textformat.size") { showSettings = true }
                    .disabled(session == nil)
                Button("Go to page", systemImage: "number") {
                    goToPageText = session.flatMap { $0.currentPage.map { String($0 + 1) } } ?? ""
                    showGoToPage = true
                }
                .disabled(session == nil || session?.pagination.totalPages == 0)
                Menu("Debug", systemImage: "ladybug") {
                    Button("Jump to last chapter") {
                        guard let session, let last = session.publication.linearReadingOrder.last else { return }
                        Task { await session.go(toSpineIndex: last.index) }
                    }
                    Button("Read through to the end") {
                        guard let session else { return }
                        Task { readThrough = await ReadThroughResult.run(session) }
                    }
                }
                .disabled(session == nil)
            }
        }
        .sheet(isPresented: $showSettings) {
            if let session {
                SettingsView(settings: Binding(get: { session.settings }, set: { session.settings = $0 }))
            }
        }
        .sheet(isPresented: $showTOC) {
            if let session {
                TOCView(session: session) { showTOC = false }
            }
        }
        .alert("Go to page", isPresented: $showGoToPage) {
            TextField("Page (1–\(session?.pagination.totalPages ?? 0))", text: $goToPageText)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Go") {
                guard let session, let page = Int(goToPageText.trimmingCharacters(in: .whitespaces)) else { return }
                Task { await session.go(toPage: page - 1) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let pagination = session?.pagination, pagination.isEstimated {
                Text("\(pagination.estimatedChapterCount) chapters are still estimates; the page may be approximate.")
            }
        }
        .task(id: book.id) {
            do {
                let container = try await EPUBContainer(url: book.url)
                let session = ReaderSession(container: container)
                for warning in container.publication.warnings {
                    print("warning: \(warning)")
                }
                self.session = session
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    @ViewBuilder private func reader(_ session: ReaderSession) -> some View {
        EPUBReaderView(session: session)
            .pageTransition(.slide)
            .readerGestures(.default)
            .onReaderEvent { event in
                switch event {
                case .externalLink(let url):
                    status = "External link: \(url.absoluteString)"
                case .error(let error):
                    status = "Error: \(error)"
                case .warning(let warning):
                    status = "Warning: \(warning)"
                case .tapped(_, let zone):
                    if zone == .center { status = "" }
                case .positionChanged, .paginationUpdated, .highlightTapped, .selectionChanged:
                    break
                }
            }
            .safeAreaInset(edge: .bottom) {
                StatusBar(session: session, status: status, readThrough: readThrough)
            }
            .preferredColorScheme(session.settings.theme.isDark ? .dark : nil)
    }
}

struct StatusBar: View {
    let session: ReaderSession
    let status: String
    let readThrough: ReadThroughResult?

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("Chapter \(chapterOrdinal)/\(session.publication.linearReadingOrder.count)")
                Text("·")
                Text("Page \(session.currentPageIndex + 1)/\(session.chapterPageCount)")
                Text("·")
                Text(session.totalProgression, format: .percent.precision(.fractionLength(0)))
                if session.isLoading {
                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                }
                Spacer()
                if session.isAtEnd { Text("END").bold() }
            }
            .font(.footnote.monospacedDigit())
            // Fixed heights: a spinner appearing must not change the inset, or the viewport (and with it the layout
            // key) would change every time the pagination state flips.
            .frame(height: 18)
            .accessibilityIdentifier("status.position")
            HStack(spacing: 4) {
                // Book-wide page numbers from BookPagination: "≈" while some chapters are still estimates.
                let pagination = session.pagination
                if let page = session.currentPage {
                    Text("Book page \(page + 1)")
                } else {
                    Text("Book page –")
                }
                Text("/")
                Text("\(pagination.isEstimated ? "≈" : "")\(pagination.totalPages)")
                if pagination.isEstimated {
                    Text("(estimating \(pagination.estimatedChapterCount) of \(pagination.chapters.count) chapters)")
                        .foregroundStyle(.secondary)
                    ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                } else {
                    Text("(measured)").foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.writingMode.isVertical ? "vertical" : "horizontal")
                    .foregroundStyle(.secondary)
                if session.isRightToLeft { Text("RTL").foregroundStyle(.secondary) }
            }
            .font(.caption2.monospacedDigit())
            .frame(height: 16)
            .accessibilityIdentifier("status.bookPage")
            if let readThrough {
                Text("Read through: \(readThrough.chapters) chapters, \(readThrough.pages) pages in \(readThrough.seconds, format: .number.precision(.fractionLength(1))) s\(readThrough.errors.isEmpty ? "" : ", errors: \(readThrough.errors.count)")")
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !status.isEmpty {
                Text(status).font(.caption2).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var chapterOrdinal: Int {
        (session.publication.linearReadingOrder.firstIndex { $0.index == session.currentSpineIndex } ?? 0) + 1
    }
}

/// Walks every page from the current position to the end, as a reader tapping "next" would.
struct ReadThroughResult {
    var chapters = 0
    var pages = 0
    var seconds: Double = 0
    var errors: [String] = []

    @MainActor static func run(_ session: ReaderSession) async -> ReadThroughResult {
        var result = ReadThroughResult()
        let start = ContinuousClock.now
        var lastSpine = -1
        var guardCounter = 0
        while !session.isAtEnd, guardCounter < 20_000 {
            guardCounter += 1
            let before = (session.currentSpineIndex, session.currentPageIndex)
            await session.goForward()
            let after = (session.currentSpineIndex, session.currentPageIndex)
            if before == after {
                result.errors.append("stuck at spine \(after.0) page \(after.1)")
                break
            }
            result.pages += 1
            if after.0 != lastSpine {
                lastSpine = after.0
                result.chapters += 1
            }
        }
        result.seconds = Double((ContinuousClock.now - start).components.seconds) + Double((ContinuousClock.now - start).components.attoseconds) / 1e18
        return result
    }
}

struct SettingsView: View {
    @Binding var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    private enum FontOption: String, CaseIterable, Identifiable {
        case publisher = "Publisher", system = "System", georgia = "Georgia", helvetica = "Helvetica"
        var id: String { rawValue }
        var choice: ReaderSettings.FontChoice {
            switch self {
            case .publisher: .publisher
            case .system: .system(name: "-apple-system")
            case .georgia: .system(name: "Georgia")
            case .helvetica: .system(name: "Helvetica")
            }
        }
        static func from(_ choice: ReaderSettings.FontChoice) -> FontOption {
            allCases.first { $0.choice == choice } ?? .publisher
        }
    }

    private enum ThemeOption: String, CaseIterable, Identifiable {
        case light = "Light", sepia = "Sepia", dark = "Dark"
        var id: String { rawValue }
        var theme: ReaderTheme {
            switch self {
            case .light: .light
            case .sepia: .sepia
            case .dark: .dark
            }
        }
        static func from(_ theme: ReaderTheme) -> ThemeOption {
            allCases.first { $0.theme == theme } ?? .light
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Font", selection: Binding(get: { FontOption.from(settings.font) }, set: { settings.font = $0.choice })) {
                    ForEach(FontOption.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("Size \(settings.fontScale, format: .number.precision(.fractionLength(2)))") {
                    Slider(value: $settings.fontScale, in: 0.7...2.2, step: 0.1)
                }
                LabeledContent("Line height \(settings.lineHeight, format: .number.precision(.fractionLength(1)))") {
                    Slider(value: $settings.lineHeight, in: 1.0...2.4, step: 0.1)
                }
                LabeledContent("Margins \(Int(settings.pageMargins.horizontal))") {
                    Slider(value: Binding(get: { settings.pageMargins.horizontal }, set: { settings.pageMargins = PageMargins(horizontal: $0, vertical: $0 * 0.8) }), in: 0...64, step: 4)
                }
                Picker("Theme", selection: Binding(get: { ThemeOption.from(settings.theme) }, set: { settings.theme = $0.theme })) {
                    ForEach(ThemeOption.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Button("Reset") { settings = ReaderSettings() }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        .padding()
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}

struct TOCView: View {
    let session: ReaderSession
    let onSelect: () -> Void

    private var entries: [TOCEntry] {
        func flatten(_ list: [TOCEntry]) -> [TOCEntry] { list.flatMap { [$0] + flatten($0.children) } }
        return flatten(session.publication.toc)
    }

    var body: some View {
        NavigationStack {
            List(entries) { entry in
                Button {
                    Task { await session.go(to: entry) }
                    onSelect()
                } label: {
                    Text(entry.label)
                        .padding(.leading, CGFloat(entry.depth) * 16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Contents")
            .toolbar {
                Button("Done") { onSelect() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
    }
}
