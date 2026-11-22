import ImageIO
import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    let parent: UUID?
    @State private var query = ""
    @State private var chooseFiles = false
    @State private var pickedFiles: [URL]?
    @State private var pickPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importingPhotos = false
    @State private var editor: NoteDraft?
    @State private var moving: LibraryItem?
    @State private var deleting: LibraryItem?
    @State private var naming: Naming?
    @State private var draftName = ""
    @State private var presentedFile: PresentedFile?
    @State private var error: String?

    private var current: LibraryItem? { parent.flatMap(store.item) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visible: [LibraryItem] {
        guard isSearching else { return store.children(of: parent) }
        return store.items.filter { entry in
            entry.id != parent && entry.name.localizedStandardContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) &&
                (parent == nil || store.trail(to: entry.parent).contains { $0.id == parent })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if current?.kind == .subject, let subject = current?.subject, !isSearching {
                Section {
                    HStack(spacing: 12) {
                        SubjectMark(subject: subject)
                        Text(subject.title).font(.headline)
                    }
                    .padding(.vertical, 5)
                }
            }
            if !visible.isEmpty {
                if parent == nil && !isSearching {
                    Section("Предметы") {
                        ForEach(visible.filter { $0.kind == .subject }) { row($0) }
                    }
                    let loose = visible.filter { $0.kind != .subject }
                    if !loose.isEmpty {
                        Section("Мои материалы") { ForEach(loose) { row($0) } }
                    }
                } else {
                    ForEach(visible) { row($0) }
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                if isSearching {
                    ContentUnavailableView.search(text: query)
                } else if parent != nil && current == nil {
                    ContentUnavailableView("Папка недоступна", systemImage: "folder.badge.questionmark")
                } else {
                    ContentUnavailableView("Папка пуста", systemImage: "folder",
                                           description: Text("Нажми +, чтобы добавить материалы."))
                }
            }
        }
        .navigationTitle(current?.kind == .subject ? "Предмет" : current?.name ?? "Библиотека")
        .navigationBarTitleDisplayMode(parent == nil ? .large : .inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Предметы, папки и файлы")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Импортировать файлы", systemImage: "square.and.arrow.down") { chooseFiles = true }
                    Button("Добавить из Фото", systemImage: "photo.on.rectangle") { pickPhotos = true }
                    Button("Новая папка", systemImage: "folder.badge.plus") {
                        draftName = ""
                        naming = Naming(entry: nil)
                    }
                    Button("Новый конспект", systemImage: "square.and.pencil") { editor = NoteDraft() }
                } label: {
                    Image(systemName: "plus").accessibilityLabel("Добавить")
                }
                .disabled(importingPhotos || (parent != nil && current == nil))
            }
        }
        .sheet(isPresented: $chooseFiles, onDismiss: importPickedFiles) {
            LibraryDocumentPicker { selection in
                pickedFiles = selection
                chooseFiles = false
            }
        }
        .photosPicker(isPresented: $pickPhotos, selection: $photos, maxSelectionCount: 20,
                      matching: .images, preferredItemEncoding: .current)
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty else { return }
            importingPhotos = true
            Task { await importPhotos(selection) }
        }
        .sheet(item: $editor) { draft in
            NoteEditor(draft: draft, parent: parent)
        }
        .sheet(item: $moving) { entry in
            FolderPicker(title: "Переместить в папку", excluding: entry.id) { target in
                perform { try store.move(entry.id, to: target) }
                moving = nil
            }
        }
        .sheet(item: $presentedFile) { file in
            if file.preview {
                NavigationStack {
                    DocumentPreview(url: file.url)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(file.url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Готово") { presentedFile = nil }
                            }
                        }
                }
            } else {
                ShareFileView(url: file.url).presentationDetents([.medium, .large])
            }
        }
        .alert(naming?.entry == nil ? "Новая папка" : "Переименовать", isPresented: isSet($naming)) {
            TextField("Название", text: $draftName)
            Button("Сохранить") {
                if let entry = naming?.entry {
                    let ext = entry.kind == .file ? (entry.name as NSString).pathExtension : ""
                    let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    perform {
                        guard !name.isEmpty else { throw LibraryError.invalidName }
                        try store.rename(entry.id, to: ext.isEmpty ? name : name + "." + ext)
                    }
                } else {
                    perform { try store.addFolder(draftName, parent: parent) }
                }
                naming = nil
            }
            Button("Отмена", role: .cancel) { naming = nil }
        }
        .confirmationDialog("Удалить «\(deleting?.name ?? "")»?", isPresented: isSet($deleting), titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let deleting { perform { try store.remove(deleting.id) } }
                deleting = nil
            }
        } message: {
            if deleting?.kind == .folder { Text("Содержимое папки также будет удалено.") }
        }
        .alert("Не удалось выполнить действие", isPresented: isSet($error)) {
            Button("ОК") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func row(_ entry: LibraryItem) -> some View {
        HStack(spacing: 8) {
            if entry.kind.isContainer {
                NavigationLink(value: entry.id) { label(entry) }
            } else {
                Button {
                    if entry.kind == .note {
                        editor = NoteDraft(entry: entry)
                    } else {
                        showFile(entry, preview: true)
                    }
                } label: { label(entry).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }
                .buttonStyle(.plain)
            }
            if entry.kind != .subject {
                Menu { actions(entry) } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Действия с материалом")
                }
                .buttonStyle(.borderless)
            }
        }
        .contextMenu {
            if entry.kind != .subject { actions(entry) }
        }
    }

    private func label(_ entry: LibraryItem) -> some View {
        HStack(spacing: 12) {
            if let subject = entry.subject {
                SubjectMark(subject: subject)
            } else {
                Image(systemName: icon(entry))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).foregroundStyle(.primary)
                if isSearching {
                    let trail = store.trail(to: entry.parent).map(\.name).joined(separator: " / ")
                    if !trail.isEmpty { Text(trail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                } else if entry.kind == .note {
                    Text("Личный конспект").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func icon(_ entry: LibraryItem) -> String {
        if entry.kind == .note { return "note.text" }
        if entry.kind.isContainer { return "folder" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "tiff": return "photo"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        case "zip", "rar", "7z": return "archivebox"
        default: return "doc.text"
        }
    }

    @ViewBuilder private func actions(_ entry: LibraryItem) -> some View {
        if !entry.kind.isContainer {
            Button("Поделиться / выгрузить", systemImage: "square.and.arrow.up") { showFile(entry, preview: false) }
        }
        Button("Переименовать", systemImage: "pencil") {
            draftName = entry.kind == .file ? (entry.name as NSString).deletingPathExtension : entry.name
            naming = Naming(entry: entry)
        }
        Button("Переместить", systemImage: "folder") { moving = entry }
        Button("Удалить", systemImage: "trash", role: .destructive) { deleting = entry }
    }

    private func showFile(_ entry: LibraryItem, preview: Bool) {
        perform {
            let url = try store.export(entry.id)
            presentedFile = PresentedFile(url: url, preview: preview && QLPreviewController.canPreview(url as NSURL))
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { self.error = error.localizedDescription }
    }

    private func importPickedFiles() {
        guard let urls = pickedFiles else { return }
        pickedFiles = nil
        perform {
            guard !urls.isEmpty else { throw LibraryError.unavailable }
            try store.importFiles(urls, into: parent, source: .localCopy)
            query = ""
        }
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) async {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? fm.removeItem(at: folder)
            photos = []
            importingPhotos = false
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var urls: [URL] = []
            for (index, photo) in selection.enumerated() {
                guard let data = try await photo.loadTransferable(type: Data.self) else {
                    throw LibraryError.unavailable
                }
                var ext = photo.supportedContentTypes.first(where: { $0.conforms(to: .image) })?.preferredFilenameExtension
                if let image = CGImageSourceCreateWithData(data as CFData, nil),
                   let imageType = CGImageSourceGetType(image) {
                    ext = UTType(imageType as String)?.preferredFilenameExtension ?? ext
                }
                let name = "Фото \(index + 1)" + (ext.map { "." + $0 } ?? "")
                let url = folder.appendingPathComponent(name)
                try data.write(to: url)
                urls.append(url)
            }
            try store.importFiles(urls, into: parent, source: .localCopy)
        } catch { self.error = error.localizedDescription }
    }
}

private struct LibraryDocumentPicker: UIViewControllerRepresentable {
    let complete: ([URL]?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(complete: complete) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.complete = complete
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var complete: ([URL]?) -> Void

        init(complete: @escaping ([URL]?) -> Void) { self.complete = complete }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            complete(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            complete(nil)
        }
    }
}

private struct Naming {
    let entry: LibraryItem?
}

func isSet<Value>(_ binding: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
}

struct FolderPicker: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let title: String
    var excluding: UUID? = nil
    let choose: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button { choose(nil) } label: { Label("Библиотека", systemImage: "books.vertical") }
                ForEach(store.destinations(excluding: excluding)) { entry in
                    Button { choose(entry.id) } label: {
                        Label(store.trail(to: entry.id).map(\.name).joined(separator: " / "), systemImage: "folder")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}

private struct NoteDraft: Identifiable {
    var id = UUID()
    var entry: LibraryItem?
}

private struct NoteEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var content: String
    @State private var error: String?
    @State private var discard = false
    let draft: NoteDraft
    let parent: UUID?

    init(draft: NoteDraft, parent: UUID?) {
        self.draft = draft
        self.parent = draft.entry == nil ? parent : draft.entry?.parent
        _name = State(initialValue: draft.entry?.name ?? "")
        _content = State(initialValue: draft.entry?.content ?? "")
    }

    private var hasEdits: Bool { name != (draft.entry?.name ?? "") || content != (draft.entry?.content ?? "") }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $name)
                Section("Текст конспекта") {
                    TextEditor(text: $content).frame(minHeight: 240)
                }
            }
            .navigationTitle("Личный конспект")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { if hasEdits { discard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        do {
                            try store.saveNote(name, content: content, parent: parent, id: draft.entry?.id)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Отменить изменения?", isPresented: $discard, titleVisibility: .visible) {
                Button("Отменить изменения", role: .destructive) { dismiss() }
            }
            .alert("Не удалось сохранить", isPresented: isSet($error)) {
                Button("ОК") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled(hasEdits)
    }
}
