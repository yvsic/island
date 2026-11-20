import AppKit
import EventKit
import SwiftUI

/// Something to be reminded of, and when.
struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var due: Date
    /// The alert has been shown; it waits in the list until it's ticked off.
    var fired = false
    /// Its twin in the Reminders app, when there is one.
    var appID: String?
}

/// Reads a line like "call mum in 2 hours" or "dentist friday at 3pm" into a
/// title and a time. Nothing leaves the Mac: it is plain pattern matching plus
/// the system's own date detector.
enum ReminderParser {
    struct Result: Equatable {
        var title: String
        var due: Date
    }

    static func parse(_ input: String, now: Date = .now, calendar: Calendar = .current) -> Result? {
        // Keep it bounded: a pasted novel is not a reminder.
        var text = String(input.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = strip(text, #"^(?:please\s+)?(?:remind\s+me(?:\s+(?:to|about|that))?|reminder(?:\s+to|:)?|remember\s+to|don'?t\s+forget\s+to)\s+"#)

        if let (interval, range) = relative(in: text) {
            return Result(title: title(text, removing: [range]), due: now.addingTimeInterval(interval))
        }

        var removed: [Range<String.Index>] = []
        var due: Date?
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let match = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).first(where: { $0.date != nil }),
           let range = Range(match.range, in: text), var date = match.date {
            removed.append(range)
            let phrase = String(text[range])
            if !mentionsTime(phrase) {
                // A day with no time: take a bare "at 3" from the rest, or default to the morning.
                let bare = bareHour(in: text)
                if let bare { removed.append(bare.range) }
                let hour = bare.map { $0.hour < 8 ? $0.hour + 12 : $0.hour } ?? 9
                date = calendar.date(bySettingHour: min(23, hour), minute: bare?.minute ?? 0, second: 0, of: date) ?? date
            }
            // "5pm" said at six means tomorrow; a date already gone means next year.
            if date <= now {
                if calendar.isDate(date, inSameDayAs: now) {
                    date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
                } else if let next = calendar.date(byAdding: .year, value: 1, to: date), next > now {
                    date = next
                }
            }
            due = date
        } else if let bare = bareHour(in: text) {
            // "at 5" with nothing else: the next time the clock reads five.
            removed.append(bare.range)
            let hours = bare.hour < 12 ? [bare.hour, bare.hour + 12] : [bare.hour % 24]
            let today = calendar.startOfDay(for: now)
            due = [0, 1].flatMap { day in
                hours.compactMap { hour -> Date? in
                    calendar.date(byAdding: .day, value: day, to: today)
                        .flatMap { calendar.date(bySettingHour: hour, minute: bare.minute, second: 0, of: $0) }
                }
            }.filter { $0 > now }.min()
        }
        guard let due, due > now else { return nil }
        return Result(title: title(text, removing: removed), due: due)
    }

    // MARK: Pieces

    private static let numbers: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30,
        "forty five": 45, "forty-five": 45, "sixty": 60, "ninety": 90, "half a": 0.5, "half an": 0.5,
        "a half": 0.5, "a couple": 2, "a couple of": 2, "a few": 3,
    ]

    private static func seconds(per unit: String) -> Double? {
        switch unit.lowercased().first {
        case "s": 1
        case "m": 60
        case "h": 3600
        case "d": 86_400
        case "w": 604_800
        default: nil
        }
    }

    /// "in 2 hours", "in an hour and a half", "in 1h 30m", "after 45 mins".
    private static func relative(in text: String) -> (TimeInterval, Range<String.Index>)? {
        let number = #"(\d{1,4}(?:[.,]\d{1,2})?|half\s+an?|a\s+half|a\s+couple(?:\s+of)?|a\s+few|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty[- ]five|sixty|ninety)"#
        let unit = #"(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|[smhdw])"#
        let pattern = "\\b(?:in|after)\\s+\(number)\\s*\(unit)(?![a-z])(\\s+and\\s+a\\s+half)?(?:\\s*,?\\s*(?:and\\s+)?\(number)\\s*\(unit)(?![a-z]))?"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        func amount(_ raw: String?) -> Double? {
            guard let raw else { return nil }
            let key = raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return numbers[key] ?? Double(key.replacingOccurrences(of: ",", with: "."))
        }
        guard let first = amount(group(1)), let firstUnit = group(2).flatMap(seconds(per:)) else { return nil }
        var total = first * firstUnit
        if group(3) != nil { total += firstUnit / 2 }
        if let second = amount(group(4)), let secondUnit = group(5).flatMap(seconds(per:)) { total += second * secondUnit }
        // Between a few seconds and five years: anything else was a typo.
        guard total >= 5, total <= 5 * 366 * 86_400 else { return nil }
        return (total, range)
    }

    /// A lone "at 5" or "at 7:30", which the system detector leaves alone.
    private static func bareHour(in text: String) -> (hour: Int, minute: Int, range: Range<String.Index>)? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(?:at|@)\s*(\d{1,2})(?:[:.](\d{2}))?(?![\d:apAP])"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text),
              let hourRange = Range(match.range(at: 1), in: text), let hour = Int(text[hourRange]), hour <= 24 else { return nil }
        let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
        guard minute < 60 else { return nil }
        return (hour, minute, range)
    }

    private static func mentionsTime(_ phrase: String) -> Bool {
        phrase.range(of: #"\d\s*(?:am|pm|a\.m|p\.m)|\d[:.]\d\d|noon|midday|midnight|morning|afternoon|evening|tonight|night"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func strip(_ text: String, _ pattern: String) -> String {
        text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// What's left once the time is taken out, tidied into a title.
    private static func title(_ text: String, removing ranges: [Range<String.Index>]) -> String {
        var result = text
        // Later ranges first, so earlier ones stay valid.
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) where range.upperBound <= result.endIndex {
            result.replaceSubrange(range, with: " ")
        }
        result = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var previous = ""
        while previous != result {
            previous = result
            result = strip(result, #"(?:^|\s+)(?:at|on|by|in|for|this|next|the|around|about|until|till|from|and)$"#)
            result = strip(result, #"^(?:to|at|on|by|and)\s+"#)
            result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-–—"))
        }
        guard let first = result.first else { return "Reminder" }
        return first.uppercased() + result.dropFirst()
    }
}

/// Reminders set from the island. They are kept here, ring in the island when
/// due, and (if allowed) are also added to the Reminders app so they reach
/// every device.
@Observable
final class ReminderStore {
    private(set) var items: [Reminder] = []
    private(set) var appAccessDenied = false

    @ObservationIgnored var onDue: ((Reminder) -> Void)?
    @ObservationIgnored private var waiter: Task<Void, Never>?
    @ObservationIgnored private lazy var store = EKEventStore()
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var started = false
    private static let key = "reminders"
    static let limit = 50

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Reminder].self, from: data) {
            items = Array(saved.sorted { $0.due < $1.due }.prefix(Self.limit))
        }
    }

    /// The next one still to come.
    var next: Reminder? { items.first { !$0.fired } }

    func start() {
        started = true
        arm()
    }

    @discardableResult
    func add(_ parsed: ReminderParser.Result) -> Reminder? {
        guard items.count < Self.limit else { return nil }
        let reminder = Reminder(title: String(parsed.title.prefix(120)), due: parsed.due)
        items.append(reminder)
        items.sort { $0.due < $1.due }
        save()
        arm()
        if Preferences.shared.remindersToApp { addToApp(reminder) }
        return reminder
    }

    /// Ticked off or deleted: either way it leaves the list.
    func remove(_ reminder: Reminder, completed: Bool = false) {
        items.removeAll { $0.id == reminder.id }
        save()
        arm()
        guard let id = reminder.appID, !previewing,
              let twin = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        if completed {
            twin.isCompleted = true
            try? store.save(twin, commit: true)
        } else {
            try? store.remove(twin, commit: true)
        }
    }

    func snooze(_ reminder: Reminder, minutes: Int) {
        guard let index = items.firstIndex(where: { $0.id == reminder.id }) else { return }
        items[index].due = .now + Double(minutes) * 60
        items[index].fired = false
        items.sort { $0.due < $1.due }
        save()
        arm()
    }

    /// Sleeps until the next reminder is due, then rings it.
    private func arm() {
        waiter?.cancel()
        guard started, !previewing, let next else { return }
        waiter = Task { [weak self] in
            let wait = next.due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled, let self,
                  let index = self.items.firstIndex(where: { $0.id == next.id }), !self.items[index].fired else { return }
            self.items[index].fired = true
            self.save()
            self.onDue?(self.items[index])
            // Several due at once ring a moment apart, not on top of each other.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self.arm()
        }
    }

    private func save() {
        guard !previewing, let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    // MARK: Reminders app

    private func addToApp(_ reminder: Reminder) {
        guard !previewing else { return }
        Task {
            let allowed = (try? await store.requestFullAccessToReminders()) ?? false
            appAccessDenied = !allowed
            guard allowed, let list = store.defaultCalendarForNewReminders() else { return }
            let twin = EKReminder(eventStore: store)
            twin.title = reminder.title
            twin.calendar = list
            twin.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.due)
            twin.addAlarm(EKAlarm(absoluteDate: reminder.due))
            guard (try? store.save(twin, commit: true)) != nil,
                  let index = items.firstIndex(where: { $0.id == reminder.id }) else { return }
            items[index].appID = twin.calendarItemIdentifier
            save()
        }
    }

    /// For snapshots.
    func setPreview(_ reminders: [Reminder]) {
        previewing = true
        items = reminders
    }
}

/// Reminders in the open island: a line to type into, what it understood, and
/// the ones already set.
struct RemindersPanel: View {
    let model: IslandModel
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var store: ReminderStore { model.reminders }

    static func bodyHeight(rows: Int) -> CGFloat { 74 + CGFloat(min(3, max(1, rows))) * 32 + 8 }

    private var parsed: ReminderParser.Result? { ReminderParser.parse(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.setTool(nil) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.white.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .help("Back")
                TextField("Remind me to… call mum in 2 hours", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit(add)
                    .onExitCommand { model.setTool(nil) }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(.white.opacity(0.1)))
                    .onChange(of: draft) { _, text in
                        // A long paste is cut down rather than parsed whole.
                        if text.count > 300 { draft = String(text.prefix(300)) }
                    }
                Button(action: add) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(parsed == nil ? .white.opacity(0.5) : .black)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(parsed == nil ? Color.white.opacity(0.14) : Color.timerOrange))
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .disabled(parsed == nil)
                .help("Set reminder")
            }
            understood
                .frame(height: 16)
            list
        }
        .padding(.top, model.contentTop - 2)
        .padding(.horizontal, Layout.sidePadding)
        .frame(height: model.contentTop + Self.bodyHeight(rows: store.items.count), alignment: .top)
        .animation(model.prefs.reshape, value: store.items)
        .staggered(0)
        .task {
            // The panel takes the keyboard a beat after it is allowed to.
            try? await Task.sleep(for: .milliseconds(140))
            focused = true
        }
    }

    /// What the line will become, as it is typed.
    @ViewBuilder private var understood: some View {
        HStack(spacing: 5) {
            if let parsed {
                Image(systemName: "bell.fill")
                Text(parsed.title).foregroundStyle(.white)
                Text("· \(Self.when(parsed.due))")
            } else if draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Type what and when, then press Return")
            } else {
                Image(systemName: "clock")
                Text("Add a time: “in 20 minutes”, “at 5pm”, “tomorrow 9am”")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(parsed == nil ? .white.opacity(0.4) : Color.timerOrange)
        .lineLimit(1)
        .padding(.leading, 32)
    }

    @ViewBuilder private var list: some View {
        if store.items.isEmpty {
            Text("No reminders set")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.35))
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.leading, 32)
        } else {
            IslandScroll(axis: .vertical) {
                VStack(spacing: 4) {
                    ForEach(store.items) { reminder in
                        ReminderLine(reminder: reminder, store: store)
                            .transition(.islandSwap(model.prefs))
                    }
                }
            }
            .frame(height: CGFloat(min(3, store.items.count)) * 32 - 4)
        }
    }

    private func add() {
        guard let parsed else { return }
        store.add(parsed)
        draft = ""
        if model.prefs.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    /// "Today 5:42 PM", "Tomorrow 9:00 AM", "Fri 20 Nov, 3:00 PM".
    static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(time)"
    }
}

private struct ReminderLine: View {
    let reminder: Reminder
    let store: ReminderStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button { store.remove(reminder, completed: true) } label: {
                Image(systemName: reminder.fired ? "bell.badge.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(reminder.fired ? Color.timerOrange : .white.opacity(0.45))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help("Done")
            Text(reminder.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 6)
            if reminder.fired {
                Button("In 10 min") { store.snooze(reminder, minutes: 10) }
                    .buttonStyle(PillButtonStyle(compact: true))
            } else {
                Text(RemindersPanel.when(reminder.due))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Button { store.remove(reminder) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.3))
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            .help("Delete")
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(reminder.fired ? Color.timerOrange.opacity(0.16) : .white.opacity(hovering ? 0.09 : 0.05)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15).paced, value: hovering)
    }
}
