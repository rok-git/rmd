import Foundation
import Testing
@testable import rmd

@Test func completionDateCommands() throws {
    let expected = try parseCompletionDate("2026-09-28 18:30")
    let command = try parseCommand(["done", "abcd", "--done-at", "2026-09-28 18:30", "--json", "--verbose"])
    guard case let .done(id, date, json, verbose) = command else {
        Issue.record("Expected done command")
        return
    }
    #expect(id == "abcd")
    #expect(date == expected)
    #expect(json && verbose)
    guard case let .edit(options) = try parseCommand(["edit", "abcd", "--done-at", "令和8年9月28日 18:30"]) else {
        Issue.record("Expected edit command")
        return
    }
    #expect(options.doneAt == expected)
    guard case let .done(_, defaultDate, _, _) = try parseCommand(["done", "abcd"]) else {
        Issue.record("Expected done command")
        return
    }
    #expect(defaultDate == nil)
    #expect(throws: CLIError.self) { try parseCommand(["done", "abcd", "--done-at"]) }
    #expect(throws: CLIError.self) { try parseCommand(["edit", "abcd", "--done-at", "invalid"]) }
    #expect(throws: CLIError.self) { try parseCommand(["undone", "abcd", "--done-at", "2026-09-28"]) }
}

@Test func dateOnlyCompletionIsMidnight() throws {
    for input in ["2026-09-28", "昨日", "yesterday", "今日", "today"] {
        let date = try parseCompletionDate(input)
        #expect(date == Calendar.current.startOfDay(for: date))
    }
}
