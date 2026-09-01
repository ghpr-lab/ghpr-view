import Foundation

struct FindingResolution: Equatable {
    let lifecycle: FindingLifecycle
    let resolvedAnchor: DiffAnchor?
    let confidence: Double?
}

struct FindingResolver {
    static func resolve(
        finding: SkillFinding,
        currentRevision: PullRequestRevisionSubject,
        patch: ReviewPatchIndex?
    ) -> FindingResolution {
        guard case .diffLine(let original) = finding.subject,
              original.repository.lowercased() == currentRevision.repository.lowercased(),
              original.prNumber == currentRevision.prNumber else {
            return FindingResolution(
                lifecycle: .unavailable,
                resolvedAnchor: nil,
                confidence: finding.confidence
            )
        }
        if original.headSHA == currentRevision.headSHA {
            return FindingResolution(
                lifecycle: .exact,
                resolvedAnchor: original,
                confidence: finding.confidence
            )
        }
        guard let patch else {
            return FindingResolution(
                lifecycle: .unavailable,
                resolvedAnchor: nil,
                confidence: finding.confidence
            )
        }
        if let fingerprint = original.hunkFingerprint {
            let matches = patch.anchors(
                matchingHunkFingerprint: fingerprint,
                original: original,
                currentRevision: currentRevision
            )
            if matches.count == 1 {
                return FindingResolution(
                    lifecycle: .remapped,
                    resolvedAnchor: matches[0],
                    confidence: finding.confidence
                )
            }
        }
        if let quotedCode = original.quotedCode {
            let matches = patch.anchors(
                matchingQuotedCode: quotedCode,
                original: original,
                currentRevision: currentRevision
            )
            if matches.count == 1 {
                return FindingResolution(
                    lifecycle: .remapped,
                    resolvedAnchor: matches[0],
                    confidence: finding.confidence.map { min($0, 0.6) }
                )
            }
        }
        return FindingResolution(
            lifecycle: .outdated,
            resolvedAnchor: nil,
            confidence: finding.confidence
        )
    }
}

private actor FindingPatchCache {
    private struct Entry {
        let patch: ReviewPatchIndex
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]

    func value(for key: String, now: Date = Date()) -> ReviewPatchIndex? {
        guard let entry = entries[key], entry.expiresAt > now else {
            entries[key] = nil
            return nil
        }
        return entry.patch
    }

    func insert(_ patch: ReviewPatchIndex, for key: String, now: Date = Date()) {
        entries[key] = Entry(patch: patch, expiresAt: now.addingTimeInterval(60))
    }
}

struct FindingResolutionService: Sendable {
    private let ghURL: URL?
    private let runner: ExtensionCommandRunner
    private let cache: FindingPatchCache

    init(
        ghURL: URL? = GitHubSubjectResolver.executable(named: "gh"),
        runner: @escaping ExtensionCommandRunner = { executable, arguments, directory in
            try await ExtensionCommand.run(
                executable: executable,
                arguments: arguments,
                currentDirectoryURL: directory
            )
        }
    ) {
        self.ghURL = ghURL
        self.runner = runner
        self.cache = FindingPatchCache()
    }

    func resolve(
        _ finding: SkillFinding,
        currentRevision: PullRequestRevisionSubject
    ) async -> SkillFinding {
        let patchIndex: ReviewPatchIndex?
        if case .diffLine(let original) = finding.subject,
           original.headSHA != currentRevision.headSHA {
            patchIndex = try? await patch(for: currentRevision)
        } else {
            patchIndex = nil
        }
        let resolution = FindingResolver.resolve(
            finding: finding,
            currentRevision: currentRevision,
            patch: patchIndex
        )
        return SkillFinding(
            id: finding.id,
            subjectKey: finding.subjectKey,
            subject: finding.subject,
            kind: finding.kind,
            severity: finding.severity,
            title: finding.title,
            summary: finding.summary,
            details: finding.details,
            confidence: resolution.confidence,
            lifecycle: resolution.lifecycle,
            createdAt: finding.createdAt,
            fingerprint: finding.fingerprint,
            resolvedSubject: resolution.resolvedAnchor.map(GitHubSubject.diffLine)
        )
    }

    private func patch(for revision: PullRequestRevisionSubject) async throws -> ReviewPatchIndex {
        let key = "\(revision.repository.lowercased())#\(revision.prNumber)@\(revision.headSHA)"
        if let cached = await cache.value(for: key) {
            return cached
        }
        guard let ghURL else {
            throw GitHubSubjectResolverError.missingExecutable("gh")
        }
        let result = try await runner(
            ghURL,
            [
                "pr", "diff", "\(revision.prNumber)",
                "--repo", revision.repository,
                "--patch", "--color", "never"
            ],
            nil
        )
        guard result.succeeded else {
            throw GitHubSubjectResolverError.commandFailed(
                GitHubSubjectResolver.boundedDiagnostic(
                    result.stderr,
                    fallback: "Unable to load the current pull request patch with gh."
                )
            )
        }
        let patch = ReviewPatchIndex(result.stdout)
        await cache.insert(patch, for: key)
        return patch
    }
}
