import Foundation
import Testing
@testable import rmd

@Test func dueDateBounds() throws {
    let start = try parseDateBoundary("2026-09-01", isEnd: false)
    let end = try parseDateBoundary("2026-09-17", isEnd: true)
    let cases: [(String, Bool)] = [
        ("2026-08-31 23:59", false),
        ("2026-09-01", true),
        ("2026-09-17", true),
        ("2026-09-17 23:59", true),
        ("2026-09-18", false),
    ]
    for (input, expected) in cases {
        let due = try parseDateComponents(input)
        #expect(matchesDueDateRange(due, from: start, to: end) == expected)
    }
    #expect(!matchesDueDateRange(nil, from: start, to: end))
    #expect(!matchesDueDateRange(nil, from: start, to: nil))
    #expect(!matchesDueDateRange(nil, from: nil, to: end))
    #expect(matchesDueDateRange(nil, from: nil, to: nil))
    let early = try parseDateComponents("2026-08-31")
    let late = try parseDateComponents("2026-09-18")
    #expect(matchesDueDateRange(early, from: nil, to: end))
    #expect(!matchesDueDateRange(late, from: nil, to: end))
    #expect(matchesDueDateRange(late, from: start, to: nil))
    #expect(!matchesDueDateRange(early, from: start, to: nil))
}

@Test func timedUpperBoundIsExclusive() throws {
    let end = try parseDateBoundary("2026-09-17 12:00", isEnd: true)
    let before = try parseDateComponents("2026-09-17 11:59")
    let atEnd = try parseDateComponents("2026-09-17 12:00")
    #expect(matchesDueDateRange(before, from: nil, to: end))
    #expect(!matchesDueDateRange(atEnd, from: nil, to: end))
}

@Test func completedAndDueRangesRemainIndependent() throws {
    let command = try parseCommand([
        "list", "--done", "--due-from", "2026-09-01", "--due-to", "2026-09-17",
        "--done-from", "2026-09-10", "--done-to", "2026-09-12",
    ])
    guard case let .list(options) = command else {
        Issue.record("Expected list command")
        return
    }
    #expect(options.completed)
    let completionRange = makeCompletionDateRange(options)
    #expect(completionRange.start == (try parseDateBoundary("2026-09-10", isEnd: false)))
    #expect(completionRange.end == (try parseDateBoundary("2026-09-12", isEnd: true)))
    let due = try parseDateComponents("2026-09-16")
    #expect(matchesDueDateRange(due, from: options.dueFrom, to: options.dueTo))
}
