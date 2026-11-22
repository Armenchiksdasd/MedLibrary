import Foundation
import SwiftUI
import ZIPFoundation

enum LibraryError: LocalizedError {
    case invalidName, duplicateName, unavailable, invalidBackup, archiveInProgress

    var errorDescription: String? {
        switch self {
        case .invalidName: "Введите имя без косых черт."
        case .duplicateName: "В этой папке уже есть материал с таким именем."
        case .unavailable: "Этот материал или папка больше недоступны."
        case .invalidBackup: "Это повреждённая или несовместимая резервная копия."
        case .archiveInProgress: "Дождись завершения работы с архивом."
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var state: LibraryState
    @Published private(set) var archiveInProgress = false
    private let root: URL
    private let blobs: URL
    private let manifest: URL
    private let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let fm = FileManager.default

    init() throws {
        let fm = FileManager.default
        root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                          appropriateFor: nil, create: true).appendingPathComponent("StudyLibrary")
        blobs = root.appendingPathComponent("Files", isDirectory: true)
        manifest = root.appendingPathComponent("Library.json")
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        if fm.fileExists(atPath: manifest.path) {
            state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: manifest))
        } else {
            let initial = LibraryState.initial()
            try JSONEncoder().encode(initial).write(to: manifest, options: .atomic)
            state = initial
        }
        pruneBlobs()
    }

    var items: [LibraryItem] { state.items }
    func item(_ id: UUID) -> LibraryItem? { items.first { $0.id == id } }
    func children(of parent: UUID?) -> [LibraryItem] {
        items.filter { $0.parent == parent }.sorted {
            if $0.kind.isContainer != $1.kind.isContainer { return $0.kind.isContainer }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func trail(to id: UUID?) -> [LibraryItem] {
        var nodes: [LibraryItem] = []
        var cursor = id
        while let key = cursor, let entry = item(key) {
            nodes.append(entry)
            cursor = entry.parent
        }
        return nodes.reversed()
    }

    func change(for id: String) -> LessonChange { state.lessons[id] ?? LessonChange() }

    func effectiveLessons() -> [Lesson] {
        Timetable.lessons.map { $0.applying(change(for: $0.id)) }.sorted { $0.start < $1.start }
    }

    func saveChange(_ change: LessonChange, for id: String) throws {
        var next = state
        next.lessons[id] = change == LessonChange() ? nil : change
        try commit(next)
    }

    func addFolder(_ name: String, parent: UUID?) throws {
        try validateParent(parent)
        var next = state
        next.items.append(LibraryItem(parent: parent, kind: .folder, name: try validName(name, parent: parent)))
        try commit(next)
    }

    func saveNote(_ name: String, content: String, parent: UUID?, id: UUID?) throws {
        try validateParent(parent)
        let name = try validName(name, parent: parent, excluding: id)
        var next = state
        if let id {
            guard let index = next.items.firstIndex(where: { $0.id == id && $0.kind == .note }) else {
                throw LibraryError.unavailable
            }
            next.items[index].name = name
            next.items[index].content = content
        } else {
            next.items.append(LibraryItem(parent: parent, kind: .note, name: name, content: content))
        }
        try commit(next)
    }

    func rename(_ id: UUID, to name: String) throws {
        var next = state
        guard let index = items.firstIndex(where: { $0.id == id && $0.kind != .subject }) else {
            throw LibraryError.unavailable
        }
        next.items[index].name = try validName(name, parent: items[index].parent, excluding: id)
        try commit(next)
    }

    func destinations(excluding id: UUID?) -> [LibraryItem] {
        func descendants(_ parent: UUID?) -> [LibraryItem] {
            children(of: parent).filter { $0.kind.isContainer && $0.id != id }.flatMap {
                [$0] + descendants($0.id)
            }
        }
        return descendants(nil)
    }

    func move(_ id: UUID, to parent: UUID?) throws {
        try validateParent(parent)
        guard let index = items.firstIndex(where: { $0.id == id && $0.kind != .subject }),
              !trail(to: parent).contains(where: { $0.id == id }) else {
            throw LibraryError.unavailable
        }
        var next = state
        next.items[index].name = try validName(items[index].name, parent: parent, excluding: id)
        next.items[index].parent = parent
        try commit(next)
    }

    func remove(_ id: UUID) throws {
        guard let entry = item(id), entry.kind != .subject else { throw LibraryError.unavailable }
        let removed = Set(items.filter { trail(to: $0.id).contains(where: { $0.id == id }) }.map(\.id))
        var next = state
        next.items.removeAll { removed.contains($0.id) }
        for key in Array(next.lessons.keys) { next.lessons[key]?.attachments.subtract(removed) }
        try commit(next)
        pruneBlobs()
    }

    enum ImportSource {
        case externalDocument, localCopy
    }

    func importFiles(_ urls: [URL], into parent: UUID?, source: ImportSource = .externalDocument) throws {
        guard !archiveInProgress else { throw LibraryError.archiveInProgress }
        try validateParent(parent)
        var next = state
        var created: [URL] = []
        do {
            for url in urls {
                let name = uniqueName(url.lastPathComponent, parent: parent, in: next.items)
                let entry = LibraryItem(parent: parent, kind: .file, name: name)
                let target = blob(entry.id)
                created.append(target)
                try copyImport(from: url, to: target, source: source)
                next.items.append(entry)
            }
            try commit(next)
        } catch {
            created.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
    }

    private func copyImport(from url: URL, to target: URL, source: ImportSource) throws {
        func copyFile(_ readable: URL) throws {
            guard try readable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw LibraryError.unavailable
            }
            try FileManager.default.copyItem(at: readable, to: target)
        }

        switch source {
        case .localCopy:
            try copyFile(url)
        case .externalDocument:
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var copyResult: Result<Void, Error>?
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                copyResult = Result { try copyFile(readable) }
            }
            if let coordinationError { throw coordinationError }
            guard let copyResult else { throw LibraryError.unavailable }
            try copyResult.get()
        }
    }

    func export(_ id: UUID) throws -> URL {
        guard let entry = item(id), !entry.kind.isContainer else { throw LibraryError.unavailable }
        let folder = try makeStage()
        if entry.kind == .note {
            let name = entry.name.lowercased().hasSuffix(".txt") ? entry.name : entry.name + ".txt"
            let target = folder.appendingPathComponent(name)
            try (entry.content ?? "").write(to: target, atomically: true, encoding: .utf8)
            return target
        }
        let target = folder.appendingPathComponent(entry.name)
        try fm.copyItem(at: blob(id), to: target)
        return target
    }

    func backup() async throws -> URL {
        guard !archiveInProgress else { throw LibraryError.archiveInProgress }
        archiveInProgress = true
        defer { archiveInProgress = false }
        let folder = try makeStage()
        let snapshot = state
        let blobs = self.blobs
        return try await Task.detached(priority: .userInitiated) {
            try Self.writeBackup(snapshot, folder: folder, blobs: blobs)
        }.value
    }

    private nonisolated static func writeBackup(_ snapshot: LibraryState, folder: URL, blobs: URL) throws -> URL {
        let target = folder.appendingPathComponent("Учебная библиотека.zip")
        let archive = try Archive(url: target, accessMode: .create)
        let index = folder.appendingPathComponent("Library.json")
        defer { try? FileManager.default.removeItem(at: index) }
        try JSONEncoder().encode(Backup(version: 1, state: snapshot)).write(to: index)
        try archive.addEntry(with: "Library.json", fileURL: index, compressionMethod: .deflate)
        for entry in snapshot.items where entry.kind == .file {
            let name = entry.id.uuidString
            try archive.addEntry(with: "Files/\(name)", fileURL: blobs.appendingPathComponent(name),
                                 compressionMethod: .deflate)
        }
        return target
    }

    func restore(_ url: URL) async throws {
        guard !archiveInProgress else { throw LibraryError.archiveInProgress }
        archiveInProgress = true
        defer {
            archiveInProgress = false
            pruneBlobs()
        }
        let blobs = self.blobs
        let next = try await Task.detached(priority: .userInitiated) {
            try Self.readBackup(url, blobs: blobs)
        }.value
        try commit(next, restoring: true)
    }

    private nonisolated static func readBackup(_ url: URL, blobs: URL) throws -> LibraryState {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let archive = try Archive(url: url, accessMode: .read)
        guard let index = archive["Library.json"], index.type == .file,
              index.uncompressedSize <= 64 * 1024 * 1024 else { throw LibraryError.invalidBackup }
        var data = Data()
        let checksum = try archive.extract(index) { chunk in
            guard data.count + chunk.count <= 64 * 1024 * 1024 else { throw LibraryError.invalidBackup }
            data.append(chunk)
        }
        guard checksum == index.checksum else { throw LibraryError.invalidBackup }
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        guard backup.version == 1 else { throw LibraryError.invalidBackup }
        try validate(backup.state)

        var next = backup.state
        var remapped: [UUID: UUID] = [:]
        for index in next.items.indices where next.items[index].kind == .file {
            let oldID = next.items[index].id
            guard let entry = archive["Files/\(oldID.uuidString)"], entry.type == .file else {
                throw LibraryError.invalidBackup
            }
            let newID = UUID()
            let target = blobs.appendingPathComponent(newID.uuidString)
            guard try archive.extract(entry, to: target) == entry.checksum else {
                throw LibraryError.invalidBackup
            }
            remapped[oldID] = newID
            next.items[index].id = newID
        }
        for key in Array(next.lessons.keys) {
            if var change = next.lessons[key] {
                change.attachments = Set(change.attachments.map { remapped[$0] ?? $0 })
                next.lessons[key] = change
            }
        }
        return next
    }

    private struct Backup: Codable {
        let version: Int
        let state: LibraryState
    }

    private nonisolated static func validate(_ restored: LibraryState) throws {
        let nodes = Dictionary(grouping: restored.items, by: \.id)
        let subjects = restored.items.filter { $0.kind == .subject }
        let expected = Set(Subject.allCases.filter { $0 != .sports })
        guard nodes.values.allSatisfy({ $0.count == 1 }), subjects.count == expected.count,
              Set(subjects.compactMap(\.subject)) == expected else { throw LibraryError.invalidBackup }
        for entry in restored.items {
            guard isValidName(entry.name), entry.kind != .subject || entry.parent == nil else {
                throw LibraryError.invalidBackup
            }
            var visited: Set<UUID> = [entry.id]
            var parent = entry.parent
            while let id = parent {
                guard visited.insert(id).inserted, let node = nodes[id]?.first, node.kind.isContainer else {
                    throw LibraryError.invalidBackup
                }
                parent = node.parent
            }
        }
    }

    private func validateParent(_ parent: UUID?) throws {
        if let parent, item(parent)?.kind.isContainer != true { throw LibraryError.unavailable }
    }

    private nonisolated static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0") &&
            name.utf8.count <= 250
    }

    private func validName(_ value: String, parent: UUID?, excluding id: UUID? = nil) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(name) else { throw LibraryError.invalidName }
        guard !items.contains(where: {
            $0.parent == parent && $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw LibraryError.duplicateName }
        return name
    }

    private func uniqueName(_ value: String, parent: UUID?, in entries: [LibraryItem]) -> String {
        let safe = Self.isValidName(value) ? value : "Файл"
        let ext = (safe as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let base = (safe as NSString).deletingPathExtension
        var name = safe
        var number = 1
        while entries.contains(where: {
            $0.parent == parent && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            number += 1
            let candidate = "\(base) (\(number))\(suffix)"
            name = Self.isValidName(candidate) ? candidate : "Файл (\(number))"
        }
        return name
    }

    private func commit(_ next: LibraryState, restoring: Bool = false) throws {
        guard !archiveInProgress || restoring else { throw LibraryError.archiveInProgress }
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        state = next
    }

    private func blob(_ id: UUID) -> URL { blobs.appendingPathComponent(id.uuidString) }

    private func pruneBlobs() {
        let live = Set(items.filter { $0.kind == .file }.map { $0.id.uuidString })
        let stored = (try? fm.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil)) ?? []
        for url in stored where !live.contains(url.lastPathComponent) { try? fm.removeItem(at: url) }
    }

    private func makeStage() throws -> URL {
        let folder = staging.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
