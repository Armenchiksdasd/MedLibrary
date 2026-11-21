import QuickLook
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var selected = max(Timetable.firstDay, Timetable.calendar.startOfDay(for: Date()))
    @State private var chooseDate = false

    private var week: [Date] {
        let calendar = Timetable.calendar
        let weekday = calendar.component(.weekday, from: selected)
        let start = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: selected)!
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var effectiveLessons: [Lesson] { store.effectiveLessons() }

    var body: some View {
        let lessons = effectiveLessons
        let todayLessons = lessons.filter { Timetable.calendar.isDate($0.start, inSameDayAs: selected) }
        List {
            Section {
                VStack(spacing: 14) {
                    HStack {
                        weekButton(-7, icon: "chevron.left", title: "Предыдущая неделя")
                        Spacer(minLength: 4)
                        Button { chooseDate = true } label: {
                            Label(Timetable.label(selected, format: "LLLL yyyy").capitalized, systemImage: "calendar")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        Spacer(minLength: 4)
                        weekButton(7, icon: "chevron.right", title: "Следующая неделя")
                    }
                    HStack(spacing: 2) {
                        ForEach(week, id: \.self) { day in
                            dayButton(day, hasLessons: lessons.contains {
                                Timetable.calendar.isDate($0.start, inSameDayAs: day) &&
                                    !store.change(for: $0.id).cancelled
                            })
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                if todayLessons.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Пар нет", systemImage: "calendar.badge.checkmark").font(.headline)
                        if selected < Timetable.firstDay || selected > Timetable.lastDay {
                            Text("Расписание действует с 23 ноября по 30 декабря 2026.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 12)
                } else {
                    ForEach(todayLessons) { lesson in
                        if let original = Timetable.lessons.first(where: { $0.id == lesson.id }) {
                            NavigationLink { LessonDetail(original: original) } label: {
                                LessonRow(lesson: lesson, change: store.change(for: lesson.id))
                            }
                        }
                    }
                }
            } header: {
                Text(Timetable.label(selected, format: "EEEE, d MMMM"))
            }
        }
        .navigationTitle("Календарь")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Сегодня") { selected = Timetable.calendar.startOfDay(for: Date()) }
            }
        }
        .sheet(isPresented: $chooseDate) {
            NavigationStack {
                DatePicker("День", selection: $selected, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding()
                    .navigationTitle("Выбрать день")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { chooseDate = false } } }
            }
        }
        .environment(\.calendar, Timetable.calendar)
        .environment(\.timeZone, Timetable.calendar.timeZone)
        .environment(\.locale, Locale(identifier: "ru_RU"))
    }

    private func weekButton(_ days: Int, icon: String, title: String) -> some View {
        Button {
            if let date = Timetable.calendar.date(byAdding: .day, value: days, to: selected) { selected = date }
        } label: {
            Image(systemName: icon).frame(minWidth: 44, minHeight: 44).accessibilityLabel(title)
        }
        .buttonStyle(.borderless)
    }

    private func dayButton(_ day: Date, hasLessons: Bool) -> some View {
        let isSelected = Timetable.calendar.isDate(day, inSameDayAs: selected)
        return Button { selected = day } label: {
            VStack(spacing: 5) {
                Text(Timetable.label(day, format: "EE")).font(.caption2)
                Text(Timetable.label(day, format: "d")).font(.subheadline.weight(.semibold))
                Circle().fill(hasLessons ? Color.accentColor : .clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
            .background(isSelected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
            .accessibilityLabel(Timetable.label(day, format: "EEEE, d MMMM"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .buttonStyle(.plain)
    }
}

private struct LessonRow: View {
    let lesson: Lesson
    let change: LessonChange

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SubjectMark(subject: lesson.subject)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(Timetable.clock(lesson.start))–\(Timetable.clock(lesson.end))")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(lesson.subject.title).font(.headline)
                if let type = lesson.type { Text(type).font(.subheadline).foregroundStyle(.secondary) }
                Text(lesson.place).font(.subheadline).foregroundStyle(.secondary)
                if change.cancelled {
                    Label("Отменено", systemImage: "xmark.circle").foregroundStyle(.red).font(.caption)
                } else if change.ready {
                    Label("Подготовлено", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
                } else if !change.preparation.isEmpty || !change.attachments.isEmpty {
                    Label("Есть план подготовки", systemImage: "checklist").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

private struct LessonDetail: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var prepare = false
    @State private var reschedule = false
    @State private var attachment: PresentedFile?
    @State private var error: String?
    let original: Lesson

    private var change: LessonChange { store.change(for: original.id) }
    private var lesson: Lesson { original.applying(change) }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    SubjectMark(subject: lesson.subject)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(lesson.subject.title).font(.headline)
                        if let type = lesson.type { Text(type).font(.subheadline) }
                        Text(Timetable.label(lesson.start, format: "EEEE, d MMMM"))
                        Text("\(Timetable.clock(lesson.start))–\(Timetable.clock(lesson.end))")
                        Label(lesson.place, systemImage: "mappin")
                        if change.cancelled {
                            Label("Пара отменена", systemImage: "xmark.circle").foregroundStyle(.red)
                        } else if change.movedStart != nil {
                            Text("Исходная дата: \(Timetable.label(original.start, format: "d MMMM, HH:mm"))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                }
                .padding(.vertical, 5)
            }

            Section("Подготовка") {
                if !change.preparation.isEmpty { Text(change.preparation) }
                ForEach(store.items.filter { change.attachments.contains($0.id) && !$0.kind.isContainer }) { entry in
                    Button {
                        perform {
                            if entry.kind == .note {
                                attachment = PresentedFile(url: try store.export(entry.id), preview: true)
                            } else {
                                let url = try store.export(entry.id)
                                attachment = PresentedFile(url: url, preview: QLPreviewController.canPreview(url as NSURL))
                            }
                        }
                    } label: { Label(entry.name, systemImage: entry.kind == .note ? "note.text" : "doc") }
                }
                Toggle("Подготовлено", isOn: Binding(get: { change.ready }, set: { ready in
                    modify { $0.ready = ready }
                }))
                Button("Изменить план и материалы", systemImage: "checklist") { prepare = true }
            }

            Section("Это занятие") {
                Button("Перенести", systemImage: "calendar.badge.clock") { reschedule = true }
                if change.movedStart != nil {
                    Button("Вернуть исходное время") {
                        modify {
                            $0.movedStart = nil
                            $0.movedEnd = nil
                            $0.movedPlace = nil
                        }
                    }
                }
                if change.cancelled {
                    Button("Восстановить пару") { modify { $0.cancelled = false } }
                } else {
                    Button("Отменить пару", systemImage: "xmark.circle", role: .destructive) {
                        modify { $0.cancelled = true }
                    }
                }
            }
        }
        .navigationTitle("Занятие")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $prepare) { PreparationEditor(lessonID: original.id, change: change) }
        .sheet(isPresented: $reschedule) { RescheduleEditor(lesson: lesson, change: change) }
        .sheet(item: $attachment) { file in
            if file.preview {
                NavigationStack {
                    DocumentPreview(url: file.url)
                        .navigationTitle(file.url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { attachment = nil } } }
                }
            } else {
                ShareFileView(url: file.url)
            }
        }
        .alert("Не удалось выполнить действие", isPresented: isSet($error)) {
            Button("ОК") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func modify(_ body: (inout LessonChange) -> Void) {
        var next = change
        body(&next)
        perform { try store.saveChange(next, for: original.id) }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() }
        catch { self.error = error.localizedDescription }
    }
}

private struct PreparationEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LessonChange
    @State private var query = ""
    @State private var error: String?
    let lessonID: String

    init(lessonID: String, change: LessonChange) {
        self.lessonID = lessonID
        _draft = State(initialValue: change)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Что подготовить") {
                    TextEditor(text: $draft.preparation).frame(minHeight: 110)
                }
                Section("Материалы из библиотеки") {
                    TextField("Найти материал", text: $query)
                    let files = store.items.filter { !$0.kind.isContainer &&
                        (query.isEmpty || $0.name.localizedStandardContains(query)) }
                    if files.isEmpty {
                        Text("Материалов не найдено").foregroundStyle(.secondary)
                    }
                    ForEach(files) { file in
                        Toggle(isOn: Binding(get: { draft.attachments.contains(file.id) }, set: { checked in
                            if checked { draft.attachments.insert(file.id) } else { draft.attachments.remove(file.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(file.name)
                                let path = store.trail(to: file.parent).map(\.name).joined(separator: " / ")
                                if !path.isEmpty { Text(path).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Подготовка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        do { try store.saveChange(draft, for: lessonID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .alert("Не удалось сохранить", isPresented: isSet($error)) {
                Button("ОК") { error = nil }
            } message: { Text(error ?? "") }
        }
        .interactiveDismissDisabled()
    }
}

private struct RescheduleEditor: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date
    @State private var place: String
    @State private var error: String?
    let lesson: Lesson
    let change: LessonChange

    init(lesson: Lesson, change: LessonChange) {
        self.lesson = lesson
        self.change = change
        _start = State(initialValue: lesson.start)
        _end = State(initialValue: lesson.end)
        _place = State(initialValue: lesson.place)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Начало", selection: $start)
                    DatePicker("Конец", selection: $end)
                    TextField("Место", text: $place, axis: .vertical)
                } footer: {
                    Text("Время московское. Перенос применяется к одному занятию.")
                }
            }
            .navigationTitle("Перенос занятия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save).disabled(end <= start) }
            }
            .onChange(of: start) { old, new in end = end.addingTimeInterval(new.timeIntervalSince(old)) }
            .alert("Не удалось сохранить", isPresented: isSet($error)) {
                Button("ОК") { error = nil }
            } message: { Text(error ?? "") }
        }
        .environment(\.calendar, Timetable.calendar)
        .environment(\.timeZone, Timetable.calendar.timeZone)
        .interactiveDismissDisabled()
    }

    private func save() {
        var draft = change
        draft.movedStart = start
        draft.movedEnd = end
        draft.movedPlace = place.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.cancelled = false
        do { try store.saveChange(draft, for: lesson.id); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
