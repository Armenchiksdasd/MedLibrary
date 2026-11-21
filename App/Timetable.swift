import Foundation

struct Lesson: Identifiable, Sendable {
    let id: String
    let subject: Subject
    let type: String?
    let start: Date
    let end: Date
    let place: String

    func applying(_ change: LessonChange) -> Self {
        Self(id: id, subject: subject, type: type, start: change.movedStart ?? start,
             end: change.movedEnd ?? end, place: change.movedPlace ?? place)
    }
}

enum Timetable {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.firstWeekday = 2
        return calendar
    }()

    static let firstDay = date(month: 11, day: 23)
    static let lastDay = date(month: 12, day: 30)

    private static func date(month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    static func clock(_ date: Date) -> String {
        label(date, format: "HH:mm")
    }

    static func label(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static let lessons: [Lesson] = {
        let count = calendar.dateComponents([.day], from: firstDay, to: lastDay).day!
        return (0...count).flatMap { offset -> [Lesson] in
            let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            let oddWeek = (offset / 7).isMultiple(of: 2) == false
            func lesson(_ slot: Int, _ subject: Subject, _ start: Int, _ end: Int, _ place: String,
                        _ type: String? = nil) -> Lesson {
                func time(_ value: Int) -> Date {
                    calendar.date(bySettingHour: value / 100, minute: value % 100, second: 0, of: day)!
                }
                return Lesson(id: "2026-fall-\(offset)-\(slot)", subject: subject, type: type,
                              start: time(start), end: time(end), place: place)
            }
            let dol = "Долгоруковская, 4"
            let zhig = "ул. Жигулёнкова, 23"
            let star = "Старомонетный переулок, 5"
            let del = "Делегатская, 20"
            switch calendar.component(.weekday, from: day) {
            case 2:
                var sessions: [Lesson] = []
                if oddWeek { sessions.append(lesson(0, .wellness, 945, 1125, "\(dol), синий лекционный зал")) }
                sessions.append(lesson(1, .dentistry, 1125, 1210, "\(dol), 18 лекция", "Лекция"))
                sessions.append(lesson(2, .dentistry, 1240, 1505, "\(dol), строение 3, ауд. 400", "Практика"))
                return sessions
            case 3:
                return [lesson(0, .anatomy, 1240, 1550, "\(zhig), ауд. 17")]
            case 4:
                return [
                    lesson(0, oddWeek ? .chemistry : .biology, 900, 1030, star, "Лекция"),
                    lesson(1, .civics, 1040, 1210, star),
                    lesson(2, .chemistry, 1240, 1410, star),
                    lesson(3, .biology, 1420, 1550, star)
                ]
            case 5:
                return [
                    lesson(0, .latin, 900, 1030, del),
                    lesson(1, .english, 1040, 1210, del),
                    lesson(2, .computing, 1240, 1410, del)
                ]
            case 6:
                return [
                    lesson(0, .sports, 900, 1030, "ул. Авиамоторная, 40"),
                    lesson(1, .histology, 1125, 1410, zhig)
                ]
            default: return []
            }
        }
    }()
}
