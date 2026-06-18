import Foundation
@preconcurrency import EventKit

enum CLIError: LocalizedError {
    case missingCommand
    case unknownCommand(String)
    case missingValue(String)
    case unexpectedArgument(String)
    case missingTitle
    case missingIdentifier
    case reminderNotFound(String)
    case listNotFound(String)
    case noDefaultReminderList
    case invalidDate(String)
    case accessDenied(String)
    case eventKit(String)

    var errorDescription: String? {
        switch self {
        case .missingCommand:
            return "No command was provided."
        case let .unknownCommand(command):
            return "Unknown command: \(command)"
        case let .missingValue(option):
            return "Missing value for \(option)."
        case let .unexpectedArgument(argument):
            return "Unexpected argument: \(argument)"
        case .missingTitle:
            return "A reminder title is required."
        case .missingIdentifier:
            return "A reminder identifier is required."
        case let .reminderNotFound(identifier):
            return "Reminder not found: \(identifier)"
        case let .listNotFound(name):
            return "Reminder list not found: \(name)"
        case .noDefaultReminderList:
            return "No default reminder list is configured."
        case let .invalidDate(value):
            return "Invalid date: \(value). Use yyyy-MM-dd or yyyy-MM-dd HH:mm."
        case let .accessDenied(reason):
            return reason
        case let .eventKit(message):
            return message
        }
    }
}

struct ReminderRecord: Encodable, Sendable {
    let id: String
    let title: String
    let list: String
    let due: String?
    let completed: Bool
    let priority: Int
    let notes: String?
}

struct ReminderListRecord: Encodable, Sendable {
    let title: String
    let id: String
    let allowsContentModifications: Bool
}

struct ListOptions {
    var listName: String?
    var today = false
    var overdue = false
    var nextDays: Int?
    var json = false
}

struct AddOptions {
    var title: String
    var listName: String?
    var due: DateComponents?
    var note: String?
    var priority: Int?
    var json = false
}

struct EditOptions {
    var identifier: String
    var title: String?
    var listName: String?
    var due: DateComponents?
    var clearDue = false
    var note: String?
    var clearNote = false
    var priority: Int?
    var json = false
}

enum Command {
    case list(ListOptions)
    case add(AddOptions)
    case edit(EditOptions)
    case done(String, json: Bool)
    case undone(String, json: Bool)
    case lists(json: Bool)
    case help
}

@main
struct RMD {
    static func main() async {
        do {
            let command = try parseCommand(Array(CommandLine.arguments.dropFirst()))
            if case .help = command {
                printHelp()
                return
            }

            let store = EKEventStore()
            try await ReminderStore(eventStore: store).ensureAccess()

            switch command {
            case let .list(options):
                let records = try await ReminderStore(eventStore: store).list(options)
                printRecords(records, json: options.json)
            case let .add(options):
                let record = try ReminderStore(eventStore: store).add(options)
                printMutation(record, json: options.json)
            case let .edit(options):
                let record = try ReminderStore(eventStore: store).edit(options)
                printMutation(record, json: options.json)
            case let .done(identifier, json):
                let record = try ReminderStore(eventStore: store).setCompleted(true, identifier: identifier)
                printMutation(record, json: json)
            case let .undone(identifier, json):
                let record = try ReminderStore(eventStore: store).setCompleted(false, identifier: identifier)
                printMutation(record, json: json)
            case let .lists(json):
                let records = ReminderStore(eventStore: store).lists()
                printLists(records, json: json)
            case .help:
                break
            }
        } catch {
            fputs("rmd: \(error.localizedDescription)\n\n", stderr)
            printHelp(to: stderr)
            exit(1)
        }
    }
}

struct ReminderStore {
    let eventStore: EKEventStore

    func ensureAccess() async throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .fullAccess, .authorized:
            return
        case .notDetermined:
            let granted = try await requestReminderAccess()
            if !granted {
                throw CLIError.accessDenied("Reminders access was denied. Enable access in System Settings > Privacy & Security > Reminders.")
            }
        case .denied:
            throw CLIError.accessDenied("Reminders access is denied. Enable access in System Settings > Privacy & Security > Reminders.")
        case .restricted:
            throw CLIError.accessDenied("Reminders access is restricted on this Mac.")
        case .writeOnly:
            throw CLIError.accessDenied("rmd needs full Reminders access to read and update reminders.")
        @unknown default:
            throw CLIError.accessDenied("Reminders access is unavailable.")
        }
    }

    func list(_ options: ListOptions) async throws -> [ReminderRecord] {
        let calendars = try selectedCalendars(named: options.listName)
        let dateRange = makeDateRange(options)
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: dateRange.start,
            ending: dateRange.end,
            calendars: calendars
        )
        return try await reminderRecords(matching: predicate)
    }

    func add(_ options: AddOptions) throws -> ReminderRecord {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = options.title
        reminder.calendar = try calendar(named: options.listName)
        reminder.dueDateComponents = options.due
        reminder.notes = options.note
        if let priority = options.priority {
            reminder.priority = priority
        }
        try save(reminder)
        return makeRecord(reminder)
    }

    func edit(_ options: EditOptions) throws -> ReminderRecord {
        let reminder = try reminder(identifier: options.identifier)
        if let title = options.title {
            reminder.title = title
        }
        if let listName = options.listName {
            reminder.calendar = try calendar(named: listName)
        }
        if options.clearDue {
            reminder.dueDateComponents = nil
        } else if let due = options.due {
            reminder.dueDateComponents = due
        }
        if options.clearNote {
            reminder.notes = nil
        } else if let note = options.note {
            reminder.notes = note
        }
        if let priority = options.priority {
            reminder.priority = priority
        }
        try save(reminder)
        return makeRecord(reminder)
    }

    func setCompleted(_ completed: Bool, identifier: String) throws -> ReminderRecord {
        let reminder = try reminder(identifier: identifier)
        reminder.isCompleted = completed
        if completed {
            reminder.completionDate = Date()
        } else {
            reminder.completionDate = nil
        }
        try save(reminder)
        return makeRecord(reminder)
    }

    func lists() -> [ReminderListRecord] {
        eventStore.calendars(for: .reminder)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map {
                ReminderListRecord(
                    title: $0.title,
                    id: $0.calendarIdentifier,
                    allowsContentModifications: $0.allowsContentModifications
                )
            }
    }

    private func requestReminderAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error {
                        continuation.resume(throwing: CLIError.eventKit(error.localizedDescription))
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            } else {
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error {
                        continuation.resume(throwing: CLIError.eventKit(error.localizedDescription))
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
    }

    private func reminderRecords(matching predicate: NSPredicate) async throws -> [ReminderRecord] {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let records = (reminders ?? [])
                    .sorted(by: compareReminders)
                    .map(makeRecord)
                continuation.resume(returning: records)
            }
        }
    }

    private func selectedCalendars(named name: String?) throws -> [EKCalendar]? {
        guard let name else {
            return nil
        }
        return [try calendar(named: name)]
    }

    private func calendar(named name: String?) throws -> EKCalendar {
        if let name {
            guard let calendar = eventStore.calendars(for: .reminder).first(where: { $0.title == name }) else {
                throw CLIError.listNotFound(name)
            }
            return calendar
        }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw CLIError.noDefaultReminderList
        }
        return calendar
    }

    private func reminder(identifier: String) throws -> EKReminder {
        guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            throw CLIError.reminderNotFound(identifier)
        }
        return reminder
    }

    private func save(_ reminder: EKReminder) throws {
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw CLIError.eventKit(error.localizedDescription)
        }
    }

    private func makeRecord(_ reminder: EKReminder) -> ReminderRecord {
        ReminderRecord(
            id: reminder.calendarItemIdentifier,
            title: reminder.title,
            list: reminder.calendar.title,
            due: reminder.dueDateComponents.flatMap(formatDateComponents),
            completed: reminder.isCompleted,
            priority: reminder.priority,
            notes: reminder.notes
        )
    }
}

func parseCommand(_ arguments: [String]) throws -> Command {
    guard let command = arguments.first else {
        throw CLIError.missingCommand
    }

    var parser = ArgumentCursor(Array(arguments.dropFirst()))
    switch command {
    case "list":
        var options = ListOptions()
        while let argument = parser.next() {
            switch argument {
            case "--list":
                options.listName = try parser.requireValue(for: argument)
            case "--today":
                options.today = true
            case "--overdue":
                options.overdue = true
            case "--next":
                let value = try parser.requireValue(for: argument)
                guard let days = Int(value), days > 0 else {
                    throw CLIError.missingValue(argument)
                }
                options.nextDays = days
            case "--json":
                options.json = true
            default:
                throw CLIError.unexpectedArgument(argument)
            }
        }
        return .list(options)
    case "add":
        guard let title = parser.next(), !title.hasPrefix("--") else {
            throw CLIError.missingTitle
        }
        var options = AddOptions(title: title)
        while let argument = parser.next() {
            switch argument {
            case "--list":
                options.listName = try parser.requireValue(for: argument)
            case "--due":
                options.due = try parseDateComponents(try parser.requireValue(for: argument))
            case "--note":
                options.note = try parser.requireValue(for: argument)
            case "--priority":
                options.priority = try parsePriority(try parser.requireValue(for: argument))
            case "--json":
                options.json = true
            default:
                throw CLIError.unexpectedArgument(argument)
            }
        }
        return .add(options)
    case "edit":
        guard let identifier = parser.next(), !identifier.hasPrefix("--") else {
            throw CLIError.missingIdentifier
        }
        var options = EditOptions(identifier: identifier)
        while let argument = parser.next() {
            switch argument {
            case "--title":
                options.title = try parser.requireValue(for: argument)
            case "--list":
                options.listName = try parser.requireValue(for: argument)
            case "--due":
                options.due = try parseDateComponents(try parser.requireValue(for: argument))
            case "--clear-due":
                options.clearDue = true
            case "--note":
                options.note = try parser.requireValue(for: argument)
            case "--clear-note":
                options.clearNote = true
            case "--priority":
                options.priority = try parsePriority(try parser.requireValue(for: argument))
            case "--json":
                options.json = true
            default:
                throw CLIError.unexpectedArgument(argument)
            }
        }
        return .edit(options)
    case "done":
        return .done(try parseIdentifierAndJSON(&parser), json: parser.seenJSON)
    case "undone":
        return .undone(try parseIdentifierAndJSON(&parser), json: parser.seenJSON)
    case "lists":
        var json = false
        while let argument = parser.next() {
            switch argument {
            case "--json":
                json = true
            default:
                throw CLIError.unexpectedArgument(argument)
            }
        }
        return .lists(json: json)
    case "help", "--help", "-h":
        return .help
    default:
        throw CLIError.unknownCommand(command)
    }
}

struct ArgumentCursor {
    private let arguments: [String]
    private var index = 0
    var seenJSON = false

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> String? {
        guard index < arguments.count else {
            return nil
        }
        let value = arguments[index]
        index += 1
        if value == "--json" {
            seenJSON = true
        }
        return value
    }

    mutating func requireValue(for option: String) throws -> String {
        guard let value = next(), !value.hasPrefix("--") else {
            throw CLIError.missingValue(option)
        }
        return value
    }
}

func parseIdentifierAndJSON(_ parser: inout ArgumentCursor) throws -> String {
    guard let identifier = parser.next(), !identifier.hasPrefix("--") else {
        throw CLIError.missingIdentifier
    }
    while let argument = parser.next() {
        switch argument {
        case "--json":
            continue
        default:
            throw CLIError.unexpectedArgument(argument)
        }
    }
    return identifier
}

func parsePriority(_ value: String) throws -> Int {
    guard let priority = Int(value), (0...9).contains(priority) else {
        throw CLIError.missingValue("--priority")
    }
    return priority
}

func parseDateComponents(_ value: String) throws -> DateComponents {
    let calendar = Calendar.current
    if let date = DateParsers.dateTime.date(from: value) {
        return calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute], from: date)
    }
    if let date = DateParsers.dateOnly.date(from: value) {
        var components = calendar.dateComponents([.calendar, .timeZone, .year, .month, .day], from: date)
        components.isLeapMonth = false
        return components
    }
    throw CLIError.invalidDate(value)
}

enum DateParsers {
    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let outputDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

func makeDateRange(_ options: ListOptions) -> (start: Date?, end: Date?) {
    let calendar = Calendar.current
    let now = Date()
    let startOfToday = calendar.startOfDay(for: now)

    if options.today {
        return (startOfToday, calendar.date(byAdding: .day, value: 1, to: startOfToday))
    }
    if options.overdue {
        return (nil, startOfToday)
    }
    if let nextDays = options.nextDays {
        return (startOfToday, calendar.date(byAdding: .day, value: nextDays, to: startOfToday))
    }
    return (nil, nil)
}

func compareReminders(_ lhs: EKReminder, _ rhs: EKReminder) -> Bool {
    switch (lhs.dueDateComponents?.date, rhs.dueDateComponents?.date) {
    case let (left?, right?):
        if left != right {
            return left < right
        }
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    case (nil, nil):
        break
    }
    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
}

func formatDateComponents(_ components: DateComponents) -> String {
    if let date = components.date {
        if components.hour == nil && components.minute == nil {
            return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        }
        return DateParsers.outputDateTime.string(from: date)
    }
    return ""
}

func printRecords(_ records: [ReminderRecord], json: Bool) {
    if json {
        printJSON(records)
        return
    }
    if records.isEmpty {
        print("No reminders.")
        return
    }
    printTable(
        headers: ["ID", "Due", "List", "Pri", "Title"],
        rows: records.map { [shortID($0.id), $0.due ?? "-", $0.list, String($0.priority), $0.title] }
    )
}

func printLists(_ records: [ReminderListRecord], json: Bool) {
    if json {
        printJSON(records)
        return
    }
    if records.isEmpty {
        print("No reminder lists.")
        return
    }
    printTable(
        headers: ["ID", "Writable", "Title"],
        rows: records.map { [shortID($0.id), $0.allowsContentModifications ? "yes" : "no", $0.title] }
    )
}

func printMutation(_ record: ReminderRecord, json: Bool) {
    if json {
        printJSON(record)
        return
    }
    let status = record.completed ? "completed" : "saved"
    print("\(status): \(record.title)")
    print("id: \(record.id)")
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func printTable(headers: [String], rows: [[String]]) {
    let widths = headers.indices.map { index in
        ([headers[index]] + rows.map { $0[index] }).map(\.count).max() ?? 0
    }
    let header = headers.indices.map { headers[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
    print(header)
    print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
    for row in rows {
        print(row.indices.map { row[$0].padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  "))
    }
}

func shortID(_ identifier: String) -> String {
    String(identifier.prefix(8))
}

func printHelp(to file: UnsafeMutablePointer<FILE> = stdout) {
    let text = """
    Usage:
      rmd list [--list NAME] [--today | --overdue | --next DAYS] [--json]
      rmd add TITLE [--list NAME] [--due "yyyy-MM-dd HH:mm"] [--note TEXT] [--priority 0-9] [--json]
      rmd edit ID [--title TEXT] [--list NAME] [--due DATE] [--clear-due] [--note TEXT] [--clear-note] [--priority 0-9] [--json]
      rmd done ID [--json]
      rmd undone ID [--json]
      rmd lists [--json]
      rmd help
    """
    fputs(text + "\n", file)
}
