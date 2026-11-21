import SwiftUI
import UniformTypeIdentifiers
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.openURL) private var openURL
    @AppStorage("lessonNotifications") private var notifications = false
    @AppStorage("reminderMinutes") private var lead = 30
    @State private var requesting = false
    @State private var permissionMissing = false
    @State private var chooseBackup = false
    @State private var willRestore: URL?
    @State private var exportedBackup: PresentedFile?
    @State private var error: String?
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                Toggle("Напоминать о парах", isOn: Binding(get: { notifications }, set: changePermission))
                    .disabled(requesting)
                if notifications {
                    Picker("За сколько", selection: $lead) {
                        Text("15 минут").tag(15)
                        Text("30 минут").tag(30)
                        Text("1 час").tag(60)
                    }
                }
            } header: {
                Text("Уведомления")
            } footer: {
                Text("Напоминания создаются для ближайших пар и обновляются при открытии приложения.")
            }
            Section {
                Button("Выгрузить библиотеку в ZIP", systemImage: "archivebox") {
                    Task {
                        do { exportedBackup = PresentedFile(url: try await store.backup()) }
                        catch { self.error = error.localizedDescription }
                    }
                }
                Button("Восстановить из ZIP", systemImage: "arrow.counterclockwise") { chooseBackup = true }
            } header: {
                Text("Резервная копия")
            } footer: {
                Text("Архив включает файлы, папки, личные конспекты и изменения расписания. Отдельные файлы можно выгружать из библиотеки.")
            }
        }
        .navigationTitle("Настройки")
        .fileImporter(isPresented: $chooseBackup, allowedContentTypes: [.zip]) { result in
            perform { willRestore = try result.get() }
        }
        .confirmationDialog("Заменить текущую библиотеку?", isPresented: isSet($willRestore), titleVisibility: .visible) {
            Button("Восстановить и заменить", role: .destructive) {
                if let url = willRestore {
                    Task {
                        do {
                            try await store.restore(url)
                            status = "Библиотека восстановлена."
                        } catch { self.error = error.localizedDescription }
                    }
                }
                willRestore = nil
            }
        } message: {
            Text("Текущие файлы, папки, конспекты и изменения расписания будут заменены содержимым архива.")
        }
        .sheet(item: $exportedBackup) { file in ShareFileView(url: file.url) }
        .alert("Разреши уведомления в iOS", isPresented: $permissionMissing) {
            Button("Открыть настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Затем вернись сюда и включи напоминания.")
        }
        .alert("Не удалось выполнить действие", isPresented: isSet($error)) {
            Button("ОК") { error = nil }
        } message: { Text(error ?? "") }
        .alert(status ?? "", isPresented: isSet($status)) { Button("ОК") { status = nil } }
    }

    private func changePermission(_ enabled: Bool) {
        guard enabled else { notifications = false; return }
        requesting = true
        Task {
            defer { requesting = false }
            do {
                notifications = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                permissionMissing = !notifications
            } catch { self.error = error.localizedDescription }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { self.error = error.localizedDescription }
    }
}

struct ReminderInputs: Equatable {
    let active: Bool
    let enabled: Bool
    let lead: Int
    let changes: [String: LessonChange]
}

actor LessonReminders {
    static let shared = LessonReminders()

    func update(_ lessons: [Lesson], changes: [String: LessonChange], enabled: Bool, lead: Int) async {
        let center = UNUserNotificationCenter.current()
        let prefix = "lesson."
        let pending = await center.pendingNotificationRequests()
        guard !Task.isCancelled else { return }
        let old = pending.filter { $0.identifier.hasPrefix(prefix) }
        guard enabled else {
            center.removePendingNotificationRequests(withIdentifiers: old.map(\.identifier))
            let delivered = await center.deliveredNotifications()
            guard !Task.isCancelled else { return }
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) })
            return
        }
        let authorization = await center.notificationSettings()
        guard !Task.isCancelled else { return }
        guard authorization.authorizationStatus == .authorized || authorization.authorizationStatus == .provisional else {
            center.removePendingNotificationRequests(withIdentifiers: old.map(\.identifier))
            return
        }
        let now = Date()
        let calendar = Timetable.calendar
        let requests = lessons.lazy.filter { changes[$0.id]?.cancelled != true }.compactMap { lesson -> UNNotificationRequest? in
            let fire = lesson.start.addingTimeInterval(-Double(lead) * 60)
            guard fire > now else { return nil }
            let content = UNMutableNotificationContent()
            content.title = lesson.subject.title
            content.body = "\(Timetable.clock(lesson.start)) · \(lesson.place)"
            content.sound = .default
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = "\(prefix)\(lesson.id).\(Int(fire.timeIntervalSince1970))"
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }.prefix(64)
        let ids = Set(requests.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: old.map(\.identifier).filter { !ids.contains($0) })
        let existing = Dictionary(old.map { ($0.identifier, $0.content.body) }, uniquingKeysWith: { first, _ in first })
        for request in requests where existing[request.identifier] != request.content.body {
            guard !Task.isCancelled else { return }
            do { try await center.add(request) }
            catch { NSLog("Could not schedule lesson reminder: %@", error.localizedDescription) }
        }
    }
}

final class StudyAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
