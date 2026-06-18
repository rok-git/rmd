import Foundation
@preconcurrency import EventKit

enum CLIError: LocalizedError {
    case missingCommand
    case unknownCommand(String)
    case missingValue(String)
    case unexpectedArgument(String)
    case missingTitle
    case missingIdentifier
    case identifierTooShort(String)
    case ambiguousIdentifier(String, [ReminderRecord])
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
        case let .identifierTooShort(identifier):
            return "Short reminder identifiers must be at least 4 characters: \(identifier)"
        case let .ambiguousIdentifier(identifier, records):
            let rows = records
                .prefix(10)
                .map { "  \(shortID($0.id))  \($0.title)" }
                .joined(separator: "\n")
            return "Ambiguous reminder identifier: \(identifier)\nMatches:\n\(rows)"
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
    let completedAt: String?
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
    var yesterday = false
    var today = false
    var tomorrow = false
    var overdue = false
    var nextDays: Int?
    var dueFrom: Date?
    var dueTo: Date?
    var completed = false
    var completedFrom: Date?
    var completedTo: Date?
    var json = false
}

struct AddOptions {
    var title: String
    var listName: String?
    var due: DateComponents?
    var note: String?
    var priority: Int?
    var json = false
    var verbose = false
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
    var verbose = false
}

enum Command {
    case list(ListOptions)
    case show(String, json: Bool)
    case add(AddOptions)
    case edit(EditOptions)
    case done(String, json: Bool, verbose: Bool)
    case undone(String, json: Bool, verbose: Bool)
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
            case let .show(identifier, json):
                let record = try await ReminderStore(eventStore: store).show(identifier: identifier)
                printDetail(record, json: json)
            case let .add(options):
                let record = try ReminderStore(eventStore: store).add(options)
                printMutation(record, json: options.json, verbose: options.verbose)
            case let .edit(options):
                let record = try await ReminderStore(eventStore: store).edit(options)
                printMutation(record, json: options.json, verbose: options.verbose)
            case let .done(identifier, json, verbose):
                let record = try await ReminderStore(eventStore: store).setCompleted(true, identifier: identifier)
                printMutation(record, json: json, verbose: verbose)
            case let .undone(identifier, json, verbose):
                let record = try await ReminderStore(eventStore: store).setCompleted(false, identifier: identifier)
                printMutation(record, json: json, verbose: verbose)
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
        let predicate: NSPredicate
        if options.completed {
            let completionRange = makeCompletionDateRange(options)
            predicate = eventStore.predicateForCompletedReminders(
                withCompletionDateStarting: completionRange.start,
                ending: completionRange.end,
                calendars: calendars
            )
        } else {
            let dateRange = makeDueDateRange(options)
            predicate = eventStore.predicateForIncompleteReminders(
                withDueDateStarting: dateRange.start,
                ending: dateRange.end,
                calendars: calendars
            )
        }
        return try await reminderRecords(matching: predicate)
    }

    func show(identifier: String) async throws -> ReminderRecord {
        let reminder = try await reminder(identifier: identifier)
        return makeRecord(reminder)
    }

    func add(_ options: AddOptions) throws -> ReminderRecord {
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = options.title
        reminder.calendar = try calendar(named: options.listName ?? defaultListNameFromEnvironment())
        reminder.dueDateComponents = options.due
        reminder.notes = options.note
        if let priority = options.priority {
            reminder.priority = priority
        }
        try save(reminder)
        return makeRecord(reminder)
    }

    func edit(_ options: EditOptions) async throws -> ReminderRecord {
        let reminder = try await reminder(identifier: options.identifier)
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

    func setCompleted(_ completed: Bool, identifier: String) async throws -> ReminderRecord {
        let reminder = try await reminder(identifier: identifier)
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

    private func reminderRecords(matching predicate: NSPredicate, identifierPrefix: String? = nil) async throws -> [ReminderRecord] {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                let records = (reminders ?? [])
                    .filter { reminder in
                        guard let identifierPrefix else {
                            return true
                        }
                        return reminder.calendarItemIdentifier.lowercased().hasPrefix(identifierPrefix.lowercased())
                    }
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

    private func reminder(identifier: String) async throws -> EKReminder {
        if let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder {
            return reminder
        }

        guard identifier.count >= 4 else {
            throw CLIError.identifierTooShort(identifier)
        }

        let matches = try await reminderRecords(
            matching: eventStore.predicateForReminders(in: nil),
            identifierPrefix: identifier
        )
        guard let match = matches.first else {
            throw CLIError.reminderNotFound(identifier)
        }
        guard matches.count == 1 else {
            throw CLIError.ambiguousIdentifier(identifier, matches)
        }
        guard let reminder = eventStore.calendarItem(withIdentifier: match.id) as? EKReminder else {
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
            completedAt: reminder.completionDate.map(formatDate),
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
            case "--yesterday":
                options.yesterday = true
            case "--today":
                options.today = true
            case "--tomorrow":
                options.tomorrow = true
            case "--overdue":
                options.overdue = true
            case "--next":
                let value = try parser.requireValue(for: argument)
                guard let days = Int(value), days > 0 else {
                    throw CLIError.missingValue(argument)
                }
                options.nextDays = days
            case "--due-from":
                options.dueFrom = try parseDateBoundary(try parser.requireValue(for: argument), isEnd: false)
            case "--due-to":
                options.dueTo = try parseDateBoundary(try parser.requireValue(for: argument), isEnd: true)
            case "--completed":
                options.completed = true
            case "--completed-from":
                options.completed = true
                options.completedFrom = try parseDateBoundary(try parser.requireValue(for: argument), isEnd: false)
            case "--completed-to":
                options.completed = true
                options.completedTo = try parseDateBoundary(try parser.requireValue(for: argument), isEnd: true)
            case "--json":
                options.json = true
            default:
                throw CLIError.unexpectedArgument(argument)
            }
        }
        return .list(options)
    case "show":
        return .show(try parseIdentifierAndJSON(&parser), json: parser.seenJSON)
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
            case "-v", "--verbose":
                options.verbose = true
            default:
                throw CLIError.unexpectedArgument(argument)
            }
        }
        return .add(options)
    case "edit":
        guard let identifier = parser.next(), !identifier.hasPrefix("--") else {
            throw CLIError.missingIdentifier
        }
        try validateIdentifierInput(identifier)
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
            case "-v", "--verbose":
                options.verbose = true
            default:
                throw CLIError.unexpectedArgument(argument)
            }
        }
        return .edit(options)
    case "done":
        return .done(try parseIdentifierAndFlags(&parser), json: parser.seenJSON, verbose: parser.seenVerbose)
    case "undone":
        return .undone(try parseIdentifierAndFlags(&parser), json: parser.seenJSON, verbose: parser.seenVerbose)
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
    var seenVerbose = false

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
        if value == "-v" || value == "--verbose" {
            seenVerbose = true
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

func parseIdentifierAndFlags(_ parser: inout ArgumentCursor) throws -> String {
    guard let identifier = parser.next(), !identifier.hasPrefix("--") else {
        throw CLIError.missingIdentifier
    }
    try validateIdentifierInput(identifier)
    while let argument = parser.next() {
        switch argument {
        case "--json", "-v", "--verbose":
            continue
        default:
            throw CLIError.unexpectedArgument(argument)
        }
    }
    return identifier
}

func parseIdentifierAndJSON(_ parser: inout ArgumentCursor) throws -> String {
    guard let identifier = parser.next(), !identifier.hasPrefix("--") else {
        throw CLIError.missingIdentifier
    }
    try validateIdentifierInput(identifier)
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

func defaultListNameFromEnvironment() -> String? {
    guard let value = ProcessInfo.processInfo.environment["RMD_DEFAULT_LIST"] else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func validateIdentifierInput(_ identifier: String) throws {
    if identifier.count < 4 {
        throw CLIError.identifierTooShort(identifier)
    }
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

func parseDateBoundary(_ value: String, isEnd: Bool) throws -> Date {
    if let date = DateParsers.dateTime.date(from: value) {
        return date
    }
    if let date = DateParsers.dateOnly.date(from: value) {
        if isEnd {
            return Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }
    throw CLIError.invalidDate(value)
}

func makeDueDateRange(_ options: ListOptions) -> (start: Date?, end: Date?) {
    if options.dueFrom != nil || options.dueTo != nil {
        return (options.dueFrom, options.dueTo)
    }
    return makeRelativeDateRange(options)
}

func makeCompletionDateRange(_ options: ListOptions) -> (start: Date?, end: Date?) {
    if options.completedFrom != nil || options.completedTo != nil {
        return (options.completedFrom, options.completedTo)
    }
    return makeRelativeDateRange(options)
}

func makeRelativeDateRange(_ options: ListOptions) -> (start: Date?, end: Date?) {
    let calendar = Calendar.current
    let now = Date()
    let startOfToday = calendar.startOfDay(for: now)

    if options.yesterday {
        return (
            calendar.date(byAdding: .day, value: -1, to: startOfToday),
            startOfToday
        )
    }
    if options.today {
        return (startOfToday, calendar.date(byAdding: .day, value: 1, to: startOfToday))
    }
    if options.tomorrow {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        return (
            startOfTomorrow,
            startOfTomorrow.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) }
        )
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
    if lhs.isCompleted || rhs.isCompleted {
        switch (lhs.completionDate, rhs.completionDate) {
        case let (left?, right?):
            if left != right {
                return left > right
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }
    }

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

func formatDate(_ date: Date) -> String {
    DateParsers.outputDateTime.string(from: date)
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
    if records.contains(where: \.completed) {
        printTable(
            headers: ["ID", "Completed", "Due", "List", "Pri", "Title"],
            rows: records.map { [shortID($0.id), $0.completedAt ?? "-", $0.due ?? "-", $0.list, String($0.priority), $0.title] }
        )
    } else {
        printTable(
            headers: ["ID", "Due", "List", "Pri", "Title"],
            rows: records.map { [shortID($0.id), $0.due ?? "-", $0.list, String($0.priority), $0.title] }
        )
    }
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

func printDetail(_ record: ReminderRecord, json: Bool) {
    if json {
        printJSON(record)
        return
    }

    print("Title: \(record.title)")
    print("ID: \(record.id)")
    print("List: \(record.list)")
    print("Due: \(record.due ?? "-")")
    print("Completed: \(record.completed ? "yes" : "no")")
    if let completedAt = record.completedAt {
        print("Completed at: \(completedAt)")
    }
    print("Priority: \(record.priority)")
    print("")
    print("Note:")
    if let notes = record.notes, !notes.isEmpty {
        print(notes)
    } else {
        print("-")
    }
}

func printMutation(_ record: ReminderRecord, json: Bool, verbose: Bool) {
    if json {
        printJSON(record)
        return
    }
    guard verbose else {
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
      rmd list [--list NAME] [--yesterday | --today | --tomorrow | --overdue | --next DAYS | --due-from DATE | --due-to DATE] [--completed] [--completed-from DATE] [--completed-to DATE] [--json]
      rmd show ID [--json]
      rmd add TITLE [--list NAME] [--due "yyyy-MM-dd HH:mm"] [--note TEXT] [--priority 0-9] [--json] [-v|--verbose]
      rmd edit ID [--title TEXT] [--list NAME] [--due DATE] [--clear-due] [--note TEXT] [--clear-note] [--priority 0-9] [--json] [-v|--verbose]
      rmd done ID [--json] [-v|--verbose]
      rmd undone ID [--json] [-v|--verbose]
      rmd lists [--json]
      rmd help
    """
    fputs(text + "\n", file)
}
