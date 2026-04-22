import Foundation

enum CIDiagnosisMockState: String, CaseIterable, Identifiable {
    case likelyFlaky
    case likelyBlocker
    case rerunTriggered

    var id: Self { self }

    var pickerTitle: String {
        switch self {
        case .likelyFlaky:
            return String(localized: "Flaky")
        case .likelyBlocker:
            return String(localized: "Blocker")
        case .rerunTriggered:
            return String(localized: "Waiting")
        }
    }

    var statusTitle: String {
        switch self {
        case .likelyFlaky:
            return String(localized: "Likely Flaky")
        case .likelyBlocker:
            return String(localized: "Likely Blocker")
        case .rerunTriggered:
            return String(localized: "Rerun Triggered")
        }
    }
}

enum CIDiagnosisMockLaunchMode {
    case checkFlakyFirst
    case rerunNow
}

struct CIDiagnosisMockContext: Equatable {
    let repoFullName: String
    let number: Int
    let title: String
    let url: URL
}

struct CIDiagnosisMockRawExcerpt: Equatable {
    let jobName: String
    let stepName: String
    let message: String
}

struct CIDiagnosisMockPresentation: Equatable {
    let summarySecondaryText: String
    let rationaleLines: [String]
    let primaryActionTitle: String
    let primaryActionDisabled: Bool
    let secondaryActionTitle: String
    let failurePatternScript: String
    let failurePatternVariants: String
    let failurePatternFailedJobs: String
    let failurePatternCallout: String?
    let changedFilesVerdict: String
    let changedFiles: [String]
    let copilotHeadline: String
    let copilotBody: String
    let rawEvidence: [CIDiagnosisMockRawExcerpt]
    let showsProgress: Bool
}

@MainActor
final class CIDiagnosisMockViewModel: ObservableObject {
    @Published private(set) var context: CIDiagnosisMockContext
    @Published var state: CIDiagnosisMockState
    @Published var isRawEvidenceExpanded = false
    @Published private(set) var rawEvidenceFocusToken = UUID()
    @Published private(set) var isHighlightingRawEvidence = false

    init(context: CIDiagnosisMockContext, launchMode: CIDiagnosisMockLaunchMode) {
        self.context = context
        self.state = Self.initialState(for: launchMode)
    }

    func update(context: CIDiagnosisMockContext, launchMode: CIDiagnosisMockLaunchMode) {
        self.context = context
        state = Self.initialState(for: launchMode)
        isRawEvidenceExpanded = false
        isHighlightingRawEvidence = false
        rawEvidenceFocusToken = UUID()
    }

    func selectState(_ newState: CIDiagnosisMockState) {
        state = newState
        isHighlightingRawEvidence = false
    }

    func triggerRerun() {
        state = .rerunTriggered
        isHighlightingRawEvidence = false
    }

    func revealRawEvidence() {
        isRawEvidenceExpanded = true
        isHighlightingRawEvidence = true
        rawEvidenceFocusToken = UUID()
    }

    func setRawEvidenceExpanded(_ isExpanded: Bool) {
        isRawEvidenceExpanded = isExpanded
        if !isExpanded {
            isHighlightingRawEvidence = false
        }
    }

    var presentation: CIDiagnosisMockPresentation {
        switch state {
        case .likelyFlaky:
            return CIDiagnosisMockPresentation(
                summarySecondaryText: String(localized: "Low 22/100"),
                rationaleLines: [
                    String(localized: "3 failed jobs across 2 images point to the same e2e script."),
                    String(localized: "This signature has not repeated after a rerun on this SHA.")
                ],
                primaryActionTitle: String(localized: "Rerun Once"),
                primaryActionDisabled: false,
                secondaryActionTitle: String(localized: "Open Failed Jobs"),
                failurePatternScript: String(localized: "Same script: tests/e2e/auth/login.spec.ts"),
                failurePatternVariants: String(localized: "Seen in: ubuntu-22.04, ubuntu-24.04, debian-bookworm"),
                failurePatternFailedJobs: String(localized: "Failed jobs: 3"),
                failurePatternCallout: nil,
                changedFilesVerdict: String(localized: "Weak match with files changed in this PR"),
                changedFiles: ["ci/auth.yml", "tests/helpers/session.ts", "docs/ci-notes.md"],
                copilotHeadline: String(localized: "Copilot assessment: weakly related to current diff"),
                copilotBody: String(localized: "The failure overlaps helper code indirectly, but the strongest signal is repeated cross-image failure."),
                rawEvidence: Self.rawEvidence,
                showsProgress: false
            )
        case .likelyBlocker:
            return CIDiagnosisMockPresentation(
                summarySecondaryText: String(localized: "Medium 46/100"),
                rationaleLines: [
                    String(localized: "The same failure signature reappeared after 1 rerun on the same commit."),
                    String(localized: "This looks less like infra flakiness and more like a blocking issue.")
                ],
                primaryActionTitle: String(localized: "Open Failed Jobs"),
                primaryActionDisabled: false,
                secondaryActionTitle: String(localized: "Rerun Anyway"),
                failurePatternScript: String(localized: "Same script: tests/e2e/auth/login.spec.ts"),
                failurePatternVariants: String(localized: "Seen in: ubuntu-22.04, ubuntu-24.04, debian-bookworm"),
                failurePatternFailedJobs: String(localized: "Failed jobs: 3"),
                failurePatternCallout: String(localized: "Repeated after 1 rerun on this SHA"),
                changedFilesVerdict: String(localized: "Moderate overlap with helper and CI files"),
                changedFiles: ["ci/auth.yml", "tests/helpers/session.ts", "scripts/e2e-matrix.sh"],
                copilotHeadline: String(localized: "Copilot assessment: possibly related to current diff"),
                copilotBody: String(localized: "The retry repeated with the same script signature, and the changed helper paths overlap the failing test setup."),
                rawEvidence: Self.rawEvidence,
                showsProgress: false
            )
        case .rerunTriggered:
            return CIDiagnosisMockPresentation(
                summarySecondaryText: String(localized: "Waiting for fresh results"),
                rationaleLines: [
                    String(localized: "The rerun has been queued for the current commit."),
                    String(localized: "Keep reviewing the evidence while the next workflow round reports back.")
                ],
                primaryActionTitle: String(localized: "Rerun Once"),
                primaryActionDisabled: true,
                secondaryActionTitle: String(localized: "Open Failed Jobs"),
                failurePatternScript: String(localized: "Same script: tests/e2e/auth/login.spec.ts"),
                failurePatternVariants: String(localized: "Seen in: ubuntu-22.04, ubuntu-24.04, debian-bookworm"),
                failurePatternFailedJobs: String(localized: "Failed jobs: 3"),
                failurePatternCallout: nil,
                changedFilesVerdict: String(localized: "Weak match with files changed in this PR"),
                changedFiles: ["ci/auth.yml", "tests/helpers/session.ts", "docs/ci-notes.md"],
                copilotHeadline: String(localized: "Copilot assessment: weakly related to current diff"),
                copilotBody: String(localized: "The strongest signal is still the cross-image failure pattern; wait for the rerun before escalating."),
                rawEvidence: Self.rawEvidence,
                showsProgress: true
            )
        }
    }

    private static let rawEvidence: [CIDiagnosisMockRawExcerpt] = [
        CIDiagnosisMockRawExcerpt(
            jobName: "linux-ubuntu-22",
            stepName: "Run auth e2e group 3",
            message: "Timed out waiting for redirect after login callback."
        ),
        CIDiagnosisMockRawExcerpt(
            jobName: "linux-ubuntu-24",
            stepName: "Run auth e2e group 3",
            message: "Expected session cookie to be present before navigation."
        ),
        CIDiagnosisMockRawExcerpt(
            jobName: "linux-debian-bookworm",
            stepName: "Run auth e2e group 3",
            message: "Login flow stalled at /callback for 30s and exited with code 1."
        )
    ]

    private static func initialState(for launchMode: CIDiagnosisMockLaunchMode) -> CIDiagnosisMockState {
        switch launchMode {
        case .checkFlakyFirst:
            return .likelyFlaky
        case .rerunNow:
            return .rerunTriggered
        }
    }
}
