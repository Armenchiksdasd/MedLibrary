import QuickLook
import SwiftUI
import UIKit

@main
@MainActor
struct StudyLibraryApp: App {
    @UIApplicationDelegateAdaptor(StudyAppDelegate.self) private var delegate
    private let library: Result<LibraryStore, Error>

    init() { library = Result { try LibraryStore() } }

    var body: some Scene {
        WindowGroup {
            switch library {
            case .success(let store):
                StudyTabs().environmentObject(store)
            case .failure(let error):
                ContentUnavailableView("Библиотека недоступна", systemImage: "exclamationmark.folder",
                                       description: Text(error.localizedDescription))
            }
        }
    }
}

enum StudyTab: Hashable { case library, calendar, settings }

struct StudyTabs: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var phase
    @AppStorage("lessonNotifications") private var notifications = false
    @AppStorage("reminderMinutes") private var lead = 30
    @State private var tab = StudyTab.library
    @State private var path: [UUID] = []
    @State private var incoming: IncomingDocument?
    @State private var message: String?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $path) {
                LibraryView(parent: nil)
                    .navigationDestination(for: UUID.self) { id in LibraryView(parent: id) }
            }
            .tabItem { Label("Библиотека", systemImage: "books.vertical") }
            .tag(StudyTab.library)

            NavigationStack { CalendarView() }
                .tabItem { Label("Календарь", systemImage: "calendar") }
                .tag(StudyTab.calendar)

            NavigationStack { SettingsView() }
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(StudyTab.settings)
        }
        .tint(Color("AccentColor"))
        .disabled(store.archiveInProgress)
        .overlay {
            if store.archiveInProgress {
                ZStack {
                    Color.black.opacity(0.20).ignoresSafeArea()
                    ProgressView("Работа с архивом…")
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            tab = .library
            incoming = IncomingDocument(url: url)
        }
        .sheet(item: $incoming) { document in
            FolderPicker(title: "Куда добавить файл?") { destination in
                do {
                    try store.importFiles([document.url], into: destination)
                    path = store.trail(to: destination).map(\.id)
                } catch { message = error.localizedDescription }
                incoming = nil
            }
        }
        .alert("Не удалось добавить файл", isPresented: Binding(
            get: { message != nil }, set: { if !$0 { message = nil } }
        )) { Button("ОК") { message = nil } } message: { Text(message ?? "") }
        .task(id: ReminderInputs(active: phase == .active, enabled: notifications, lead: lead,
                                 changes: store.state.lessons)) {
            guard phase == .active else { return }
            await LessonReminders.shared.update(store.effectiveLessons(), changes: store.state.lessons,
                                                enabled: notifications, lead: lead)
        }
    }
}

private struct IncomingDocument: Identifiable {
    let id = UUID()
    let url: URL
}

struct PresentedFile: Identifiable {
    let id = UUID()
    let url: URL
    var preview = false
}

struct ShareFileView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DocumentPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

struct SubjectMark: View {
    let subject: Subject
    var body: some View {
        Image(systemName: subject.icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(subject.accent)
            .frame(width: 42, height: 42)
            .background(subject.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

extension Subject {
    var accent: Color {
        switch self {
        case .wellness, .biology: .teal
        case .dentistry, .computing: .blue
        case .anatomy, .histology: .pink
        case .chemistry, .latin: .purple
        case .civics, .sports: Color("WarmColor")
        case .english: .indigo
        }
    }
}
