import SwiftUI
import UniformTypeIdentifiers
import EPUB

struct Book: Identifiable, Hashable {
    let id: String
    let title: String
    let url: URL
}

enum Library {
    /// The IDPF samples bundled with the demo (also used as test fixtures).
    static let bundled: [Book] = [
        ("moby-dick", "Moby-Dick"),
        ("childrens-literature", "Children's Literature"),
        ("kusamakura-japanese-vertical-writing", "草枕 (縦書き・右綴じ)"),
        ("haruko-html-jpeg", "はるこ (FXL・右綴じ)"),
        ("page-blanche", "Page blanche (FXL)"),
        ("cole-voyage-of-life", "Voyage of Life (リフロー + FXL 絵画)"),
    ].compactMap { name, title in
        guard let url = Bundle.module.url(forResource: name, withExtension: "epub", subdirectory: "Books") else { return nil }
        return Book(id: name, title: title, url: url)
    }
}

struct LibraryView: View {
    @State private var opened: [Book] = []
    @State private var importing = false
    @State private var path: [Book] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section("Bundled samples") {
                    ForEach(Library.bundled) { book in
                        NavigationLink(book.title, value: book)
                    }
                }
                if !opened.isEmpty {
                    Section("Opened") {
                        ForEach(opened) { book in
                            NavigationLink(book.title, value: book)
                        }
                    }
                }
            }
            .navigationTitle("EPUB-Swift Demo")
            .navigationDestination(for: Book.self) { book in
                BookView(book: book)
            }
            .toolbar {
                Button("Open…", systemImage: "folder") { importing = true }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.epub]) { result in
                guard case .success(let url) = result else { return }
                _ = url.startAccessingSecurityScopedResource()
                let book = Book(id: url.path, title: url.deletingPathExtension().lastPathComponent, url: url)
                opened.append(book)
                path = [book]
            }
        }
    }
}
