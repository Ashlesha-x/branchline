import Foundation

public enum ReviewPreset: String, CaseIterable {
    case week = "本周", previousWeek = "上周", month = "本月", previousMonth = "上月", custom = "自定义"

    public func range(now: Date = Date(), calendar input: Calendar = .current) -> (Date, Date)? {
        guard self != .custom else { return nil }
        var calendar = input
        calendar.firstWeekday = 2
        let unit: Calendar.Component = self == .month || self == .previousMonth ? .month : .weekOfYear
        let current = calendar.dateInterval(of: unit, for: now)!
        let interval = self == .previousWeek || self == .previousMonth ? calendar.dateInterval(of: unit, for: current.start.addingTimeInterval(-1))! : current
        return (interval.start, calendar.date(byAdding: .day, value: -1, to: interval.end)!)
    }
}

public struct ReviewRevision: Codable, Equatable, Sendable {
    public var report: WorkReview?
    public var text: String
    public var generatedText: String?
}

public struct ReviewDraft: Codable, Equatable, Sendable {
    public var preset: String
    public var from: Date
    public var through: Date
    public var projectID: UUID?
    public var branchID: UUID?
    public var format: ReviewFormat?
    public var report: WorkReview?
    public var text = ""
    public var generatedText: String?
    public var previous: ReviewRevision?
    public init(preset: String, from: Date, through: Date) { self.preset = preset; self.from = from; self.through = through }
    public static func currentWeek(now: Date = Date()) -> ReviewDraft {
        let (from, through) = ReviewPreset.week.range(now: now)!
        return ReviewDraft(preset: ReviewPreset.week.rawValue, from: from, through: through)
    }
    public var selectedFormat: ReviewFormat { format ?? report?.style ?? .brief }
    public mutating func refreshPresetDates(now: Date = Date(), calendar: Calendar = .current) {
        if let (from, through) = ReviewPreset(rawValue: preset)?.range(now: now, calendar: calendar) {
            self.from = from
            self.through = through
        }
    }
    public var hasManualChanges: Bool { text != (generatedText ?? report?.markdown ?? "") }
    public mutating func replace(with report: WorkReview) {
        previous = self.report != nil || !text.isEmpty ? ReviewRevision(report: self.report, text: text, generatedText: generatedText) : nil
        self.report = report; text = report.markdown; generatedText = text
    }
    public mutating func undoReplacement() {
        guard let previous else { return }
        report = previous.report; text = previous.text; generatedText = previous.generatedText; self.previous = nil
    }
}

public struct ReviewDraftRepository {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> ReviewDraft? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
        guard value.version == 1 else { throw WorkspaceError("回顾暂存格式不受支持，原文件已保留。") }
        return value.draft
    }
    public func save(_ draft: ReviewDraft?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Envelope(version: 1, draft: draft)).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private struct Envelope: Codable { var version: Int; var draft: ReviewDraft? }
}
