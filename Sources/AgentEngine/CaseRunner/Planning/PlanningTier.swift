import Foundation

/// Which model plans a step's action. The strong (reasoning) model takes 60-180 s per call, the fast one 5-15 s, so the strong one is kept
/// for plans that keep being rejected and for a step that has already failed twice: a person tries the obvious thing first and thinks
/// harder only when it did not work.
enum PlanningTier: Equatable {
    /// The fast model for every request. Used to plan ahead (see `PlanPrefetch`); a rejected plan made ahead is not used.
    case fast
    /// The fast model for the first two requests; the strong one only when both plans were rejected (named something not on screen, or did not validate).
    case escalating
    /// The strong model straight away.
    case strong

    /// For the narrative: which model plans.
    var title: String {
        switch self {
        case .fast: "the fast model"
        case .escalating: "the fast model (the strong one if its plan is rejected)"
        case .strong: "the strong reasoning model"
        }
    }

    /// `attempt` counts the tries at one step: 1 is the first, 2 follows a judge that disagreed once, 3 follows two.
    static func choose(attempt: Int) -> PlanningTier {
        attempt >= 3 ? .strong : .escalating
    }
}
