import AppKit
import SwiftUI

/// A day the user asked to count down to.
struct Countdown: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var date: Date
    /// Comes round every year (a birthday), rather than once (a trip).
    var yearly = false
}

/// A birthday or public holiday found in the Calendar app.
struct SpecialDay: Equatable {
    enum Kind: Equatable { case birthday, holiday }
    var title: String
    var date: Date
    var kind: Kind
}

/// A countdown ready to show: what, when, and how many days away.
struct CountdownItem: Identifiable, Equatable {
    var id: String
    var title: String
    var date: Date
    var days: Int
    var symbol: String
    var tint: Color

    /// "Today", "Tomorrow" or "in 12 days".
    var daysText: String {
        switch days {
        case 0: "Today"
        case 1: "Tomorrow"
        default: "in \(days) days"
        }
    }
}

/// The user's own countdowns, saved across restarts.
@Observable
final class CountdownStore {
    private(set) var custom: [Countdown] = []
    @ObservationIgnored private var previewing = false
    private static let key = "countdowns"
    static let limit = 20

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Countdown].self, from: data) {
            custom = Array(saved.prefix(Self.limit))
        }
    }

    func add(title: String, date: Date, yearly: Bool) {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, custom.count < Self.limit else { return }
        custom.append(Countdown(title: String(name.prefix(40)), date: Calendar.current.startOfDay(for: date), yearly: yearly))
        save()
    }

    func remove(_ countdown: Countdown) {
        custom.removeAll { $0.id == countdown.id }
        save()
    }

    /// Everything still ahead, nearest first: the user's own, then the calendar's.
    func upcoming(special: [SpecialDay], now: Date = .now) -> [CountdownItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func days(to date: Date) -> Int {
            calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        }
        var list: [CountdownItem] = []
        for item in custom {
            var date = item.date
            if item.yearly {
                // This year's occurrence, or next year's if it has passed.
                let parts = calendar.dateComponents([.month, .day], from: item.date)
                date = calendar.nextDate(after: today.addingTimeInterval(-1), matching: parts,
                                         matchingPolicy: .nextTime) ?? item.date
            }
            let left = days(to: date)
            guard left >= 0 else { continue }
            list.append(CountdownItem(id: item.id.uuidString, title: item.title, date: date, days: left,
                                      symbol: item.yearly ? "gift.fill" : "calendar.badge.clock",
                                      tint: Color(red: 0.66, green: 0.5, blue: 1.0)))
        }
        for day in special {
            let left = days(to: day.date)
            guard left >= 0 else { continue }
            list.append(CountdownItem(id: "cal-\(day.title)-\(Int(day.date.timeIntervalSince1970))", title: day.title,
                                      date: day.date, days: left,
                                      symbol: day.kind == .birthday ? "gift.fill" : "sparkles",
                                      tint: day.kind == .birthday ? Color(red: 1.0, green: 0.45, blue: 0.6)
                                                                  : Color(red: 1.0, green: 0.8, blue: 0.3)))
        }
        return list.sorted { ($0.days, $0.title) < ($1.days, $1.title) }
    }

    private func save() {
        guard !previewing, let data = try? JSONEncoder().encode(custom) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// For snapshots.
    func setPreview(_ countdowns: [Countdown]) {
        previewing = true
        custom = countdowns
    }

    /// The island has no text fields in Settings, so a new countdown is asked
    /// for in a small system prompt: a name, a day, and whether it repeats.
    func askForNew() {
        let alert = NSAlert()
        alert.messageText = "Count down to what?"
        alert.informativeText = "Island shows it beside the camera as the day gets close."
        let name = NSTextField(string: "")
        name.placeholderString = "e.g. Holiday"
        name.frame = NSRect(x: 0, y: 58, width: 260, height: 24)
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 26, width: 160, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.dateValue = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
        let yearly = NSButton(checkboxWithTitle: "Every year (a birthday or anniversary)", target: nil, action: nil)
        yearly.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 84))
        box.addSubview(name)
        box.addSubview(picker)
        box.addSubview(yearly)
        alert.accessoryView = box
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        add(title: name.stringValue, date: picker.dateValue, yearly: yearly.state == .on)
    }
}

/// A countdown beside the camera: what it is on one side, how long on the other.
enum CountdownWing {
    static let titleLimit: CGFloat = 118

    static func leadingWidth(_ item: CountdownItem?) -> CGFloat {
        guard let item else { return 0 }
        return 16 + 5 + min(titleLimit, TextWidth.of(item.title, size: 13, weight: .semibold))
    }

    static func trailingWidth(_ item: CountdownItem?) -> CGFloat {
        guard let item else { return 0 }
        return TextWidth.of(item.daysText, size: 13, weight: .semibold, digits: true)
    }
}

struct CountdownLeading: View {
    let item: CountdownItem

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: item.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 16)
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: CountdownWing.titleLimit, alignment: .leading)
                .fixedSize()
        }
    }
}

struct CountdownTrailing: View {
    let item: CountdownItem

    var body: some View {
        Text(item.daysText)
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(item.days <= 1 ? item.tint : .white.opacity(0.6))
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
    }
}
