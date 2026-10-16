import Foundation

/// The pinned plan bar: "Plan 3/7 · Write tests".
struct PlanSummary: Equatable, Sendable {
    var done: Int
    var total: Int
    /// The item in progress, or else the next one to do.
    var current: String?

    static func make(_ plan: [PlanEntry]) -> PlanSummary? {
        guard !plan.isEmpty else { return nil }
        let done = plan.filter { $0.status == "completed" }.count
        let current =
            plan.first(where: { $0.status == "in_progress" })?.content
            ?? plan.first(where: { $0.status == "pending" })?.content
        return PlanSummary(done: done, total: plan.count, current: current.map(Self.oneLine))
    }

    var isComplete: Bool { done >= total }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

enum PlanItemState: Equatable, Sendable {
    case pending, inProgress, completed, other

    init(_ status: String) {
        switch status {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        default: self = .other
        }
    }
}
