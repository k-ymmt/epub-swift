import SwiftUI
import EPUB

/// One open book: the reader view, a status bar, and sheets for the table of contents, the settings, the saved
/// highlights and search. Highlights and the last position are saved per book (`BookStore`) and restored on open.
struct BookView: View {
    let book: Book

    @State private var session: ReaderSession?
    @State private var store: BookStore?
    @State private var restorePending = false
    @State private var showHighlights = false
    @State private var showSearch = false
    @State private var tappedHighlight: Highlight?
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var status = ""
    @State private var readThrough: ReadThroughResult?
    @State private var showGoToPage = false
    @State private var goToPageText = ""
    @State private var note: NoteContent?
    @State private var image: ImageItem?
    @State private var pendingExternalURL: URL?
    /// Where to return after following a link or going to a note (the app's business; the library only reports).
    @State private var backStack: [ReadingPosition] = []
    @State private var previousPosition: ReadingPosition?
    @State private var lastPosition: ReadingPosition?
    @Environment(\.openURL) private var openURL

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
                if !backStack.isEmpty {
                    Button("Back", systemImage: "arrow.uturn.backward") {
                        guard let session, let target = backStack.popLast() else { return }
                        Task { await session.go(to: target) }
                    }
                }
                Button("Contents", systemImage: "list.bullet") { showTOC = true }
                    .disabled(session == nil)
                Button("Settings", systemImage: "textformat.size") { showSettings = true }
                    .disabled(session == nil)
                Button("Highlights", systemImage: "highlighter") { showHighlights = true }
                    .disabled(session == nil)
                Button("Search", systemImage: "magnifyingglass") { showSearch = true }
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
        .sheet(isPresented: $showHighlights) {
            if let session, let store {
                HighlightsView(session: session, store: store) { showHighlights = false }
            }
        }
        .sheet(isPresented: $showSearch) {
            if let session {
                SearchView(session: session) { showSearch = false }
            }
        }
        .alert("Highlight", isPresented: Binding(get: { tappedHighlight != nil }, set: { if !$0 { tappedHighlight = nil } }), presenting: tappedHighlight) { highlight in
            Button("Delete", role: .destructive) {
                store?.highlights.removeAll { $0.id == highlight.id }
            }
            Button("Cancel", role: .cancel) {}
        } message: { highlight in
            Text(highlight.note ?? highlight.range.description)
        }
        .onChange(of: store?.highlights) { _, highlights in
            session?.highlights = highlights ?? []
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
        .confirmationDialog("Open external link?", isPresented: Binding(get: { pendingExternalURL != nil }, set: { if !$0 { pendingExternalURL = nil } }), presenting: pendingExternalURL) { url in
            Button("Open \(url.host() ?? url.absoluteString)") { openURL(url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text(url.absoluteString)
        }
        .sheet(item: $image) { item in
            ImageViewer(item: item)
        }
        .task(id: book.id) {
            do {
                let container = try await EPUBContainer(url: book.url)
                let session = ReaderSession(container: container)
                for warning in container.publication.warnings {
                    print("warning: \(warning)")
                }
                let store = BookStore(bookID: book.id)
                session.highlights = store.highlights
                // The session loads its first chapter once the view has a size; the saved position is applied on
                // the first `positionChanged` (see `reader(_:)`).
                restorePending = store.position != nil
                self.store = store
                self.session = session
            } catch {
                loadError = String(describing: error)
            }
        }
    }

    private func addHighlight(_ selected: SelectedText, style: Highlight.Style) {
        let highlight = Highlight(range: selected.range, style: style, note: selected.text)
        store?.highlights.append(highlight)
        session?.clearSelection()
        status = "Highlighted \(selected.range.description)"
    }

    @ViewBuilder private func reader(_ session: ReaderSession) -> some View {
        EPUBReaderView(session: session)
            .pageTransition(.slide)
            .readerGestures(.default)
            .selectionActions([
                SelectionAction(title: "Highlight", systemImage: "highlighter") { selected in
                    addHighlight(selected, style: .background(ReaderColor(hex: 0xFFE066, alpha: 0.6)))
                },
                SelectionAction(title: "Underline", systemImage: "underline") { selected in
                    addHighlight(selected, style: .underline(ReaderColor(hex: 0xE0453A)))
                },
            ])
            .onReaderEvent { event in
                switch event {
                case .externalLink(let url):
                    // M5: the library never navigates away; the app asks, then opens the browser.
                    status = "External link: \(url.absoluteString)"
                    pendingExternalURL = url
                case .internalLink(let cfi):
                    status = "Link → \(cfi.description)"
                    // The session has already moved (and published the new position): go back to the one before.
                    if let previousPosition { backStack.append(previousPosition) }
                case .noteref(let content):
                    note = content
                case .imageTapped(let tapped):
                    image = ImageItem(image: tapped)
                case .error(let error):
                    status = "Error: \(error)"
                case .warning(let warning):
                    status = "Warning: \(warning)"
                case .tapped(_, let zone):
                    if zone == .center { status = "" }
                case .positionChanged(let position):
                    if restorePending, let saved = store?.position {
                        // First position after the initial load: go back to where the book was closed.
                        restorePending = false
                        Task { await session.go(to: saved) }
                    } else {
                        store?.position = position
                    }
                    previousPosition = lastPosition
                    lastPosition = position
                case .highlightTapped(let id, _):
                    tappedHighlight = store?.highlights.first { $0.id == id }
                case .selectionChanged(let selected):
                    status = selected.map { "Selected: \($0.range.description)" } ?? ""
                case .paginationUpdated:
                    break
                case .zoomChanged(let zoomed):
                    status = zoomed ? "Zoomed in: pinch out (or turn a page) to return" : ""
                }
            }
            // M5: the note a noteref points at, anchored to the noteref's box (page coordinates = this view's).
            .popover(isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } }),
                     attachmentAnchor: .rect(.rect(note?.sourceRect ?? .zero))) {
                if let note {
                    NotePopover(note: note) {
                        self.note = nil
                        if let here = session.position { backStack.append(here) }
                        if let cfi = note.cfi { Task { await session.go(to: cfi) } }
                    }
                    .presentationCompactAdaptation(.popover)
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
                // M4: the face kind (spread of which spine items, fixed layout, zoom).
                if session.isShowingSpread {
                    Text("spread \(session.visibleSpineIndices.map(String.init).joined(separator: "+"))")
                        .foregroundStyle(.secondary)
                } else {
                    Text("single").foregroundStyle(.secondary)
                }
                if session.publication.readingOrder[session.currentSpineIndex].isFixedLayout {
                    Text("FXL").foregroundStyle(.secondary)
                }
                if session.isZoomed { Text("ZOOM").bold() }
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
            // Always present, so a message appearing (selection, error) does not change the inset height.
            Text(status.isEmpty ? " " : status)
                .font(.caption2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 14)
                .accessibilityIdentifier("status.message")
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
                // M4: auto = two pages when the viewport is landscape (and the book allows it); never / always force it.
                Picker("Spread", selection: $settings.spreadPolicy) {
                    Text("Auto").tag(ReaderSettings.SpreadPolicy.auto)
                    Text("Never").tag(ReaderSettings.SpreadPolicy.never)
                    Text("Always").tag(ReaderSettings.SpreadPolicy.always)
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

/// The text of a footnote / endnote (M5 `ReaderEvent.noteref`), with a button to go to the note itself.
struct NotePopover: View {
    let note: NoteContent
    let goToNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(note.text ?? "The note could not be found (\(note.path)#\(note.fragment ?? "")).")
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            HStack {
                Text(note.isInSameDocument ? "Note in this chapter" : "Note in \(note.path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // A note in this chapter is taken out of the page flow (hidden), so there is nothing to go to.
                if !note.isInSameDocument {
                    Button("Go to note", action: goToNote)
                        .disabled(note.cfi == nil)
                }
            }
        }
        .padding()
        .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
        .accessibilityIdentifier("note.popover")
    }
}

/// `TappedImage` for `.sheet(item:)`.
struct ImageItem: Identifiable {
    let id = UUID()
    let image: TappedImage
}

/// A tapped image (M5 `ReaderEvent.imageTapped`), loaded from the container with `TappedImage.data`.
struct ImageViewer: View {
    let item: ImageItem
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: Image?
    @State private var failure: String?
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            Group {
                if let loaded {
                    // Fit to the sheet at zoom 1; zooming grows the frame so that the scroll view can pan over it.
                    GeometryReader { geometry in
                        let zoom = scale * pinch
                        ScrollView([.horizontal, .vertical]) {
                            loaded
                                .resizable()
                                .scaledToFit()
                                .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                        }
                        .defaultScrollAnchor(.center)
                        .gesture(MagnifyGesture()
                            .updating($pinch) { value, state, _ in state = value.magnification }
                            .onEnded { value in scale = min(max(1, scale * value.magnification), 6) })
                        .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2.5 }
                        .accessibilityLabel(item.image.alt ?? "Image")
                    }
                } else if let failure {
                    ContentUnavailableView("Could not load the image", systemImage: "photo", description: Text(failure))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(item.image.alt.flatMap { $0.isEmpty ? nil : $0 } ?? item.image.path ?? item.image.url.lastPathComponent)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
        .task {
            do {
                let data = try await item.image.data()
                #if os(iOS)
                if let image = UIImage(data: data) { loaded = Image(uiImage: image) } else { failure = "Unsupported format (\(data.count) bytes)" }
                #else
                if let image = NSImage(data: data) { loaded = Image(nsImage: image) } else { failure = "Unsupported format (\(data.count) bytes)" }
                #endif
            } catch {
                failure = String(describing: error)
            }
        }
    }
}
