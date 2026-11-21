import Foundation

enum Subject: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case wellness, dentistry, anatomy, biology, chemistry, civics, latin, english, computing, histology, sports
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wellness: "Формирование здорового образа жизни"
        case .dentistry: "Пропедевтическая стоматология"
        case .anatomy: "Анатомия"
        case .biology: "Биология"
        case .chemistry: "Химия"
        case .civics: "Основы российской государственности"
        case .latin: "Латынь"
        case .english: "Английский"
        case .computing: "Информатика"
        case .histology: "Гистология"
        case .sports: "Физкультура"
        }
    }

    var icon: String {
        switch self {
        case .wellness: "heart.text.clipboard"
        case .dentistry: "cross.case"
        case .anatomy: "figure.stand"
        case .biology: "leaf"
        case .chemistry: "flask"
        case .civics: "building.columns"
        case .latin: "text.book.closed"
        case .english: "bubble.left.and.bubble.right"
        case .computing: "laptopcomputer"
        case .histology: "circle.hexagongrid"
        case .sports: "figure.run"
        }
    }
}

enum ItemKind: String, Codable, Hashable, Sendable {
    case subject, folder, file, note

    var isContainer: Bool { self == .folder || self == .subject }
}

struct LibraryItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var parent: UUID?
    var kind: ItemKind
    var name: String
    var subject: Subject? = nil
    var content: String? = nil
}

struct LessonChange: Codable, Equatable, Sendable {
    var preparation = ""
    var ready = false
    var attachments: Set<UUID> = []
    var cancelled = false
    var movedStart: Date?
    var movedEnd: Date?
    var movedPlace: String?
}

struct LibraryState: Codable, Sendable {
    var items: [LibraryItem]
    var lessons: [String: LessonChange] = [:]

    static func initial() -> Self {
        let items = Subject.allCases.filter { $0 != .sports }.flatMap { subject in
            let root = LibraryItem(kind: .subject, name: subject.title, subject: subject)
            let folders = ["Лекции", "Учебники", "Шпаргалки", "Конспекты", "Тесты"].map {
                LibraryItem(parent: root.id, kind: .folder, name: $0)
            }
            return [root] + folders
        }
        return Self(items: items)
    }
}
