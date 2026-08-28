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
        sourcePRs.filter { pr in
            guard FacetPredicate.matchesText(pr, searchText: searchText) else { return false }
            return selections.allSatisfy { selectedField, keys in
                selectedField == field || keys.isEmpty || !FacetValues.values(for: selectedField, pr: pr).filter { keys.contains($0.key) }.isEmpty
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
    static func matchesText(_ pr: PullRequest, searchText: String) -> Bool {
        let parsed = PRSearchScope.parse(searchText)
        if parsed.kind != .all { return true }
        guard !parsed.term.isEmpty else { return true }
        return [pr.title, pr.repoFullName, pr.author, pr.jiraTicket ?? "", pr.jiraTitle ?? "", pr.jiraStatusName ?? "", pr.jiraStatusCategoryKey ?? "", (pr.jiraLabels ?? []).joined(separator: " "), String(pr.number)]
            .contains { PRSearchScope.contains(parsed.term, in: $0) }
    }

    static func matches(_ pr: PullRequest, searchText: String, selections: [FacetFieldID: Set<String>], legacy: (PullRequest) -> Bool) -> Bool {
        guard legacy(pr), matchesText(pr, searchText: searchText) else { return false }
        return selections.allSatisfy { field, keys in
            keys.isEmpty || !Set(FacetValues.values(for: field, pr: pr).map(\.key)).isDisjoint(with: keys)
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
