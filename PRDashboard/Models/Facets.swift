import Foundation

enum FacetProvider: String, Codable { case github, jira, pr }

enum FacetFieldID: String, Codable, CaseIterable {
    case githubLabel, githubMilestone, jiraLabel, jiraProject, ciStatus

    var title: String {
        switch self {
        case .githubLabel: return "Labels"
        case .githubMilestone: return "Milestones"
        case .jiraLabel: return "Labels"
        case .jiraProject: return "Projects"
        case .ciStatus: return "CI Status"
        }
    }
    var symbolName: String {
        switch self {
        case .githubLabel: return "tag"
        case .githubMilestone: return "flag"
        case .jiraLabel: return "tag.fill"
        case .jiraProject: return "folder"
        case .ciStatus: return "checkmark.circle"
        }
    }
    var provider: FacetProvider {
        switch self { case .githubLabel, .githubMilestone: return .github; case .jiraLabel, .jiraProject: return .jira; case .ciStatus: return .pr }
    }
    var providerTitle: String {
        switch provider { case .github: return "GitHub"; case .jira: return "Jira"; case .pr: return "Pull Request" }
    }
}

struct FacetOption: Identifiable, Hashable, Codable {
    let id: String
    let provider: FacetProvider
    let field: FacetFieldID
    let key: String
    let displayName: String
    let color: String?
    let count: Int
    var isUnavailable: Bool { count == 0 }
}

struct ActiveFacetSelection: Codable, Equatable {
    let field: FacetFieldID
    var selectedKeys: Set<String>
}

struct FacetChip: Identifiable, Hashable {
    let field: FacetFieldID
    let key: String
    let displayName: String
    let provider: FacetProvider
    var id: String { "\(field.rawValue):\(key)" }
}

enum FacetValues {
    static func normalized(_ value: String, uppercase: Bool = false) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return uppercase ? trimmed.uppercased() : trimmed.lowercased()
    }
    static func values(for field: FacetFieldID, pr: PullRequest) -> [(key: String, name: String, color: String?)] {
        switch field {
        case .githubLabel:
            return (pr.githubLabels ?? []).compactMap { label in
                let key = normalized(label.name); guard !key.isEmpty else { return nil }
                return (key, label.name.trimmingCharacters(in: .whitespacesAndNewlines), label.color)
            }
        case .githubMilestone:
            guard let milestone = pr.githubMilestone else { return [] }
            let key = normalized(milestone.title); guard !key.isEmpty else { return [] }
            return [(key, milestone.title.trimmingCharacters(in: .whitespacesAndNewlines), nil)]
        case .jiraLabel:
            return (pr.jiraLabels ?? []).compactMap { label in
                let key = normalized(label); guard !key.isEmpty else { return nil }
                return (key, label.trimmingCharacters(in: .whitespacesAndNewlines), nil)
            }
        case .jiraProject:
            guard let project = pr.jiraProjectKey else { return [] }
            let key = normalized(project, uppercase: true); guard !key.isEmpty else { return [] }
            return [(key, project.trimmingCharacters(in: .whitespacesAndNewlines), nil)]
        case .ciStatus:
            let status = pr.ciStatus?.rawValue ?? CIStatus.unknown.rawValue
            return [(status, status, nil)]
        }
    }
}

struct FacetIndexBuilder {
    let sourcePRs: [PullRequest]
    let searchText: String
    let selections: [FacetFieldID: Set<String>]

    func facetBasePRs(for field: FacetFieldID) -> [PullRequest] {
        let parsedSearch = PRSearchScope.parse(searchText)
        return sourcePRs.filter { pr in
            guard FacetPredicate.matchesSearch(pr, parsedSearch: parsedSearch) else { return false }
            return selections.allSatisfy { selectedField, keys in
                selectedField == field ||
                    keys.isEmpty ||
                    FacetValues.values(for: selectedField, pr: pr).contains { keys.contains($0.key) }
            }
        }
    }

    func options(for field: FacetFieldID) -> [FacetOption] {
        var byKey: [String: FacetOption] = [:]
        for pr in facetBasePRs(for: field) {
            var seenKeys = Set<String>()
            for value in FacetValues.values(for: field, pr: pr) where seenKeys.insert(value.key).inserted {
                if let prior = byKey[value.key] {
                    byKey[value.key] = FacetOption(id: prior.id, provider: field.provider, field: field, key: value.key, displayName: prior.displayName, color: prior.color ?? value.color, count: prior.count + 1)
                } else {
                    byKey[value.key] = FacetOption(id: "\(field.rawValue):\(value.key)", provider: field.provider, field: field, key: value.key, displayName: value.name, color: value.color, count: 1)
                }
            }
        }
        for key in selections[field] ?? [] where byKey[key] == nil {
            byKey[key] = FacetOption(id: "\(field.rawValue):\(key)", provider: field.provider, field: field, key: key, displayName: key, color: nil, count: 0)
        }
        return byKey.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

enum FacetPredicate {
    static func matchesSearch(_ pr: PullRequest, parsedSearch: PRSearchScope.Parsed) -> Bool {
        switch parsedSearch.kind {
        case .all:
            guard !parsedSearch.term.isEmpty else { return true }
            return [
                pr.title,
                pr.repoFullName,
                pr.author,
                pr.jiraTicket ?? "",
                pr.jiraTitle ?? "",
                pr.jiraStatusName ?? "",
                pr.jiraStatusCategoryKey ?? "",
                (pr.jiraLabels ?? []).joined(separator: " "),
                String(pr.number)
            ].contains { PRSearchScope.contains(parsedSearch.term, in: $0) }
        case .jira:
            return parsedSearch.term.isEmpty
                ? hasAnyJiraField(pr)
                : matchesJiraFields(pr, term: parsedSearch.term)
        case .ci:
            return matchesCIState(pr, term: parsedSearch.term)
        case .pr:
            return matchesPRState(pr, term: parsedSearch.term)
        case .approval:
            return matchesApprovalCount(pr, term: parsedSearch.term)
        }
    }

    static func matches(
        _ pr: PullRequest,
        parsedSearch: PRSearchScope.Parsed,
        selections: [FacetFieldID: Set<String>]
    ) -> Bool {
        guard matchesSearch(pr, parsedSearch: parsedSearch) else { return false }
        return selections.allSatisfy { field, keys in
            keys.isEmpty || FacetValues.values(for: field, pr: pr).contains { keys.contains($0.key) }
        }
    }

    private static func hasAnyJiraField(_ pr: PullRequest) -> Bool {
        pr.jiraTicket?.isEmpty == false ||
            pr.jiraTitle?.isEmpty == false ||
            pr.jiraStatusName?.isEmpty == false ||
            pr.jiraStatusCategoryKey?.isEmpty == false ||
            pr.jiraLabels?.isEmpty == false
    }

    private static func matchesJiraFields(_ pr: PullRequest, term: String) -> Bool {
        if let ticket = pr.jiraTicket, PRSearchScope.contains(term, in: ticket) { return true }
        if let title = pr.jiraTitle, PRSearchScope.contains(term, in: title) { return true }
        if let status = pr.jiraStatusName, PRSearchScope.contains(term, in: status) { return true }
        if let category = pr.jiraStatusCategoryKey, PRSearchScope.contains(term, in: category) { return true }
        if let labels = pr.jiraLabels,
           labels.contains(where: { PRSearchScope.contains(term, in: $0) }) {
            return true
        }
        return false
    }

    private static func matchesCIState(_ pr: PullRequest, term: String) -> Bool {
        switch term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "any", "value":
            return pr.ciStatus != nil || pr.checkTotalCount > 0 || pr.ciIsRunning
        case "pass", "passed", "success", "green":
            return pr.ciStatus == .success
        case "failure", "fail", "failed", "failing", "red":
            return pr.ciStatus == .failure || pr.ciStatus == .unknown || pr.checkFailureCount > 0
        case "running", "pending", "inflight", "in-flight":
            return pr.ciIsInFlight
        default:
            return false
        }
    }

    private static func matchesPRState(_ pr: PullRequest, term: String) -> Bool {
        switch term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "conflict", "conflicts":
            return pr.hasBaseConflicts
        default:
            return false
        }
    }

    private static func matchesApprovalCount(_ pr: PullRequest, term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pr.approvalCount > 0 }

        let operators = [">=", "<=", "==", ">", "<", "="]
        let matchedOperator = operators.first { trimmed.hasPrefix($0) }
        let operation = matchedOperator ?? "="
        let numberText = String(trimmed.dropFirst(matchedOperator?.count ?? 0))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expected = Int(numberText) else { return false }

        switch operation {
        case ">=": return pr.approvalCount >= expected
        case ">": return pr.approvalCount > expected
        case "<=": return pr.approvalCount <= expected
        case "<": return pr.approvalCount < expected
        case "=", "==": return pr.approvalCount == expected
        default: return false
        }
    }
}

struct SavedView: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var selections: [ActiveFacetSelection]
    var searchText: String
}

final class SavedViewStore {
    static let key = "PRDashboard.SavedViews"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var views: [SavedView] {
        guard let data = defaults.data(forKey: Self.key), let result = try? JSONDecoder().decode([SavedView].self, from: data) else { return [] }
        return result
    }
    private func persist(_ views: [SavedView]) { if let data = try? JSONEncoder().encode(views) { defaults.set(data, forKey: Self.key) } }
    @discardableResult func create(name: String, selections: [ActiveFacetSelection], searchText: String) -> SavedView? { let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { return nil }; let view = SavedView(id: UUID(), name: trimmed, selections: selections, searchText: searchText); persist(views + [view]); return view }
    func update(_ view: SavedView) { persist(views.map { $0.id == view.id ? view : $0 }) }
    func delete(_ view: SavedView) { persist(views.filter { $0.id != view.id }) }
}
