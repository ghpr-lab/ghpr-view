import SwiftUI

@MainActor
final class OnboardingManager: ObservableObject {
    enum Step: Int, CaseIterable, Hashable, Identifiable {
        case filter
        case repoFilter
        case myPRs
        case reviewRequests
        case mergedToday
        case unresolvedComments
        case myReviewStatus
        case approvals

        var id: Int { rawValue }

        var message: LocalizedStringKey {
            switch self {
            case .filter:
                return "Too many PRs? Search here, or filter by repo in Settings."
            case .repoFilter:
                return "Open Settings to filter by specific org or repo."
            case .myPRs:
                return "Here are your PRs."
            case .reviewRequests:
                return "Here are PRs requesting your review."
            case .mergedToday:
                return "Here are PRs merged in the last 24 hours."
            case .unresolvedComments:
                return "This is the total unresolved comments you received."
            case .myReviewStatus:
                return "This shows your review state: ⏳ waiting, 🟥 changes requested, 🟨 changes resolved, ✅ approved."
            case .approvals:
                return "This shows how many approvals this PR has received."
            }
        }

    }

    @Published private(set) var current: Step?

    private let defaults = UserDefaults.standard
    private let hasSeenKey = "PRDashboard.HasSeenOnboarding"
    private var availableSteps: Set<Step> = []

    func updateAvailableSteps(_ steps: Set<Step>) {
        availableSteps = steps

        guard let current else { return }
        guard !steps.contains(current) else { return }

        advance(from: current)
    }

    func startIfNeeded() {
        guard current == nil else { return }
        guard !hasSeen else { return }

        current = nextAvailableStep(after: nil)
    }

    func next() {
        advance(from: current)
    }

    func skip() {
        finish()
    }

    func dismissCurrentStep() {
        guard current != nil else { return }
        finish()
    }

    func reset() {
        hasSeen = false
        current = nextAvailableStep(after: nil)
    }

    func isLastAvailableStep(_ step: Step) -> Bool {
        nextAvailableStep(after: step) == nil
    }

    func progressText(for step: Step) -> String {
        let ordered = Step.allCases.filter { availableSteps.contains($0) }
        guard let idx = ordered.firstIndex(of: step) else { return "" }
        return "\(idx + 1)/\(ordered.count)"
    }

    private var hasSeen: Bool {
        get { defaults.bool(forKey: hasSeenKey) }
        set { defaults.set(newValue, forKey: hasSeenKey) }
    }

    private func advance(from step: Step?) {
        if let nextStep = nextAvailableStep(after: step) {
            current = nextStep
        } else {
            finish()
        }
    }

    private func nextAvailableStep(after step: Step?) -> Step? {
        let rawValue = step?.rawValue ?? -1
        return Step.allCases.first { $0.rawValue > rawValue && availableSteps.contains($0) }
    }

    private func finish() {
        hasSeen = true
        current = nil
    }
}
