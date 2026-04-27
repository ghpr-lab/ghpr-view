import Foundation

struct LocalSnapshotInput {
    let appVersion: String
    let buildVersion: String
    let bundleIdentifier: String
    let authState: AuthState
    let prList: PRList
    let rateLimitInfo: RateLimitInfo
    let pinnedPRIdentifiers: Set<String>
    let refreshStatus: String
    let refreshError: String?
}

enum LocalSnapshotFactory {
    static func makeSnapshot(
        input: LocalSnapshotInput,
        now: Date = Date()
    ) -> LocalSnapshot {
        let authoredPRs = input.prList.authoredPRs
        let reviewRequestPRs = input.prList.reviewRequestPRs
        let mergedLast24hPRs = mergedLast24h(from: input.prList.mergedPullRequests, now: now)

        let authoredSnapshots = sortPRs(
            authoredPRs,
            pinnedPRIdentifiers: input.pinnedPRIdentifiers,
            pinnedFirst: true
        ).map {
            makePRSnapshot(
                $0,
                section: .authored,
                pinnedPRIdentifiers: input.pinnedPRIdentifiers
            )
        }

        let reviewSnapshots = sortPRs(
            reviewRequestPRs,
            pinnedPRIdentifiers: input.pinnedPRIdentifiers
        ).map {
            makePRSnapshot(
                $0,
                section: .review,
                pinnedPRIdentifiers: input.pinnedPRIdentifiers
            )
        }

        let mentionedSnapshots = sortPRs(
            input.prList.mentionedPullRequests,
            pinnedPRIdentifiers: input.pinnedPRIdentifiers
        ).map {
            makePRSnapshot(
                $0,
                section: .mentioned,
                pinnedPRIdentifiers: input.pinnedPRIdentifiers
            )
        }

        let mergedSnapshots = sortPRs(
            mergedLast24hPRs,
            pinnedPRIdentifiers: input.pinnedPRIdentifiers,
            sortByMergedDate: true
        ).map {
            makePRSnapshot(
                $0,
                section: .merged,
                pinnedPRIdentifiers: input.pinnedPRIdentifiers
            )
        }

        return LocalSnapshot(
            schemaVersion: LocalAPIProtocol.schemaVersion,
            generatedAt: now,
            app: LocalAppSnapshot(
                version: input.appVersion,
                build: input.buildVersion,
                bundleIdentifier: input.bundleIdentifier
            ),
            auth: LocalAuthSnapshot(
                isAuthenticated: input.authState.isAuthenticated,
                username: input.authState.username,
                method: input.authState.authMethod?.rawValue
            ),
            refresh: LocalRefreshSnapshot(
                status: input.refreshStatus,
                isLoading: input.prList.isLoading,
                lastUpdated: input.prList.lastUpdated,
                error: input.refreshError ?? input.prList.error?.localizedDescription
            ),
            rateLimit: LocalRateLimitSnapshot(
                limit: input.rateLimitInfo.limit,
                remaining: input.rateLimitInfo.remaining,
                resetAt: input.rateLimitInfo.resetDate,
                isLow: input.rateLimitInfo.isLow
            ),
            summary: LocalSummarySnapshot(
                authored: authoredPRs.count,
                reviewRequests: reviewRequestPRs.count,
                mentioned: input.prList.mentionedPullRequests.count,
                mergedLast24h: mergedLast24hPRs.count,
                totalUnresolved: input.prList.totalUnresolvedCount,
                authoredUnresolved: input.prList.authoredUnresolvedCount,
                readyToMerge: authoredPRs.filter {
                    $0.approvalCount > 0 &&
                    $0.ciStatus == .success &&
                    ($0.changesRequestedCount ?? 0) == 0
                }.count,
                changesRequested: authoredPRs.filter {
                    ($0.changesRequestedCount ?? 0) > 0
                }.count,
                ciFailing: input.prList.pullRequests.filter {
                    $0.ciStatus == .failure || $0.ciStatus == .unknown
                }.count,
                ciRunning: input.prList.pullRequests.filter(\.ciIsRunning).count,
                waitingForMyReview: reviewRequestPRs.filter {
                    $0.myReviewStatus == .waiting
                }.count
            ),
            pullRequests: LocalPRSectionsSnapshot(
                authored: authoredSnapshots,
                reviewRequests: reviewSnapshots,
                mentioned: mentionedSnapshots,
                mergedLast24h: mergedSnapshots
            )
        )
    }

    private static func mergedLast24h(from prs: [PullRequest], now: Date) -> [PullRequest] {
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        var seen = Set<Int>()
        return prs.filter { pr in
            guard let mergedAt = pr.mergedAt else { return false }
            return mergedAt >= cutoff
        }.filter { pr in
            seen.insert(pr.id).inserted
        }
    }

    private static func sortPRs(
        _ prs: [PullRequest],
        pinnedPRIdentifiers: Set<String>,
        pinnedFirst: Bool = false,
        sortByMergedDate: Bool = false
    ) -> [PullRequest] {
        prs.sorted { lhs, rhs in
            if pinnedFirst {
                let lhsPinned = pinnedPRIdentifiers.contains(lhs.pinIdentifier)
                let rhsPinned = pinnedPRIdentifiers.contains(rhs.pinIdentifier)
                if lhsPinned != rhsPinned {
                    return lhsPinned
                }
            }

            let lhsDate = sortByMergedDate ? (lhs.mergedAt ?? lhs.updatedAt) : lhs.updatedAt
            let rhsDate = sortByMergedDate ? (rhs.mergedAt ?? rhs.updatedAt) : rhs.updatedAt
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            if lhs.repoFullName != rhs.repoFullName {
                return lhs.repoFullName < rhs.repoFullName
            }

            return lhs.number < rhs.number
        }
    }

    private static func makePRSnapshot(
        _ pr: PullRequest,
        section: LocalPRSection,
        pinnedPRIdentifiers: Set<String>
    ) -> LocalPRSnapshot {
        LocalPRSnapshot(
            id: pr.id,
            section: section,
            repository: pr.repoFullName,
            number: pr.number,
            title: pr.title,
            author: pr.author,
            url: pr.url.absoluteString,
            state: pr.state.rawValue,
            isDraft: pr.isDraft,
            isPinned: pinnedPRIdentifiers.contains(pr.pinIdentifier),
            hasBaseConflicts: pr.hasBaseConflicts,
            unresolvedCount: pr.unresolvedCount,
            ciStatus: pr.ciStatus?.rawValue,
            checkSuccessCount: pr.checkSuccessCount,
            checkFailureCount: pr.checkFailureCount,
            checkPendingCount: pr.checkPendingCount,
            ciIsRunning: pr.ciIsRunning,
            approvalCount: pr.approvalCount,
            changesRequestedCount: pr.changesRequestedCount,
            myReviewStatus: pr.myReviewStatus?.rawValue,
            jiraTicket: pr.jiraTicket,
            updatedAt: pr.updatedAt,
            mergedAt: pr.mergedAt
        )
    }
}
