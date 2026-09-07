import Foundation

struct SkillPackageManifest: Equatable {
    let apiVersion: String
    let id: String
    let version: String
    let displayName: String
    let targets: [SkillTarget]
    let agents: [SkillAgent]
    let defaultAgent: SkillAgent
    let timeoutSeconds: Int
    let isolation: String
    let workspaceCheckout: String
    let workspaceCWD: String
    let workspaceAccess: String
    let shellAccess: String
    let networkAccess: String
    let automationEnabled: Bool
    let autoApplyTags: Bool
    let contextIncludes: [String]
    let resultSchemaPath: String
    let presentationPath: String
    let browserContributionsPath: String?
    let browserCompanionPath: String?
    let adapter: String?

    var definition: SkillDefinition {
        return SkillDefinition(
            id: id,
            version: version,
            displayName: displayName,
            summary: "Installed ghpr Skill",
            targets: targets,
            agents: agents,
            defaultAgent: defaultAgent,
            isBuiltIn: false,
            hasBrowserCompanion: browserCompanionPath != nil,
            isRunnable: adapter == nil &&
                isolation == "strict" &&
                workspaceCheckout == "none" &&
                workspaceCWD == "run_root" &&
                workspaceAccess == "read_only" &&
                shellAccess == "denied" &&
                networkAccess == "denied" &&
                SkillAgentDiscovery.runnableAgents.contains(defaultAgent)
        )
    }
}

struct SkillPackage: Equatable {
    let rootURL: URL
    let manifest: SkillPackageManifest
    let resultSchemaURL: URL
    let presentationURL: URL
    let browserContributionsURL: URL?
    let browserCompanionURL: URL?
}

enum SkillPackageIssueSeverity: String, Codable {
    case error
    case warning
}

struct SkillPackageIssue: Codable, Equatable, Identifiable {
    var id: String { "\(severity.rawValue):\(path):\(message)" }
    let severity: SkillPackageIssueSeverity
    let path: String
    let message: String
}

struct SkillPackageValidation: Codable, Equatable {
    let valid: Bool
    let issues: [SkillPackageIssue]
}

enum SkillPackageError: LocalizedError {
    case invalidManifest([SkillPackageIssue])
    case destinationExists(String)
    case sourceMissing(String)
    case fixtureMismatch(String)
    case resultMismatch(String)
    case unsafeIdentifier(String)
    case unsafePath(String)
    case commandFailed(String)
    case existingUserSkill(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let issues):
            return issues.map(\.message).joined(separator: "\n")
        case .resultMismatch(let message):
            return message
        case .destinationExists(let path):
            return "The destination already exists: \(path)"
        case .sourceMissing(let path):
            return "The source does not exist: \(path)"
        case .fixtureMismatch(let message):
            return message
        case .unsafeIdentifier(let id):
            return "The Skill id is not safe: \(id)"
        case .unsafePath(let path):
            return "The package path escapes the Skill directory: \(path)"
        case .commandFailed(let message):
            return message
        case .existingUserSkill(let path):
            return "An unmanaged user Skill already exists at \(path)."
        }
    }
}

enum SkillPackageManager {
    static let generatedMarker = "<!-- generated-by: ghpr-skill-builder -->"

    static func load(at rootURL: URL) throws -> SkillPackage {
        let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let manifestURL = try resolvedPackagePath(
            "ghpr.skill.yaml",
            under: canonicalRoot,
            requireRegularFile: true
        )
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
        let manifest = try parseManifest(text)
        return SkillPackage(
            rootURL: canonicalRoot,
            manifest: manifest,
            resultSchemaURL: try resolvedPackagePath(
                manifest.resultSchemaPath,
                under: canonicalRoot
            ),
            presentationURL: try resolvedPackagePath(
                manifest.presentationPath,
                under: canonicalRoot
            ),
            browserContributionsURL: try manifest.browserContributionsPath.map {
                try resolvedPackagePath($0, under: canonicalRoot)
            },
            browserCompanionURL: try manifest.browserCompanionPath.map {
                try resolvedPackagePath($0, under: canonicalRoot)
            }
        )
    }

    static func resolvedPackagePath(
        _ relativePath: String,
        under rootURL: URL,
        requireRegularFile: Bool = false
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !(relativePath as NSString).isAbsolutePath else {
            throw SkillPackageError.unsafePath(relativePath)
        }
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard contains(candidate, in: root) else {
            throw SkillPackageError.unsafePath(relativePath)
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard contains(resolved, in: root) else {
            throw SkillPackageError.unsafePath(relativePath)
        }
        if requireRegularFile {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: resolved.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                throw SkillPackageError.sourceMissing(relativePath)
            }
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw SkillPackageError.sourceMissing(relativePath)
            }
        }
        return resolved
    }

    static func readTextResource(
        _ relativePath: String,
        under rootURL: URL
    ) throws -> String {
        let url = try resolvedPackagePath(
            relativePath,
            under: rootURL,
            requireRegularFile: true
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        candidate.path == root.path ||
            candidate.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    private static func ensureNoEscapingSymlinks(in rootURL: URL) throws {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        var traversalError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                traversalError = error
                return false
            }
        ) else {
            throw SkillPackageError.sourceMissing(root.path)
        }
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true else { continue }
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
            guard !(target as NSString).isAbsolutePath else {
                throw SkillPackageError.unsafePath(
                    entry.path.replacingOccurrences(of: root.path + "/", with: "")
                )
            }
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            guard contains(resolved, in: root) else {
                throw SkillPackageError.unsafePath(
                    entry.path.replacingOccurrences(of: root.path + "/", with: "")
                )
            }
        }
        if let traversalError {
            throw traversalError
        }
    }

    static func parseManifest(_ text: String) throws -> SkillPackageManifest {
        let document = SimpleYAMLDocument(text)
        var issues: [SkillPackageIssue] = []

        func required(_ key: String) -> String {
            guard let value = document.scalar(key), !value.isEmpty else {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: "ghpr.skill.yaml",
                        message: "Missing required field '\(key)'."
                    )
                )
                return ""
            }
            return value
        }

        let apiVersion = required("api_version")
        let id = required("id")
        let version = required("version")
        let displayName = required("display_name")
        let targetValues = document.list("targets")
        let agentValues = document.list("execution.agents")
        let defaultAgentValue = required("execution.default_agent")
        let timeout = Int(document.scalar("execution.timeout_seconds") ?? "") ?? 600
        let isolation = document.scalar("execution.isolation") ?? "strict"
        let workspaceCheckout = document.scalar("workspace.checkout") ?? "none"
        let workspaceCWD = document.scalar("workspace.cwd") ?? "run_root"
        let resultSchemaPath = required("result.schema")
        let contextIncludes = document.list("context.include")
        let presentationPath = required("presentation.file")

        if apiVersion != GHPRContract.skillVersion {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "Unsupported api_version '\(apiVersion)'."
                )
            )
        }
        if !isSafeIdentifier(id) {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "Skill id must use letters, numbers, dots, underscores, or hyphens."
                )
            )
        }

        let targets = targetValues.compactMap(SkillTarget.init(rawValue:))
        if targets.count != targetValues.count || targets.isEmpty {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "targets contains an unsupported or empty target."
                )
            )
        }
        let agents = agentValues.compactMap(SkillAgent.init(rawValue:))
        if agents.count != agentValues.count || agents.isEmpty {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "execution.agents must contain a supported agent."
                )
            )
        }
        let defaultAgent = SkillAgent(rawValue: defaultAgentValue) ?? .omp
        if !agents.contains(defaultAgent) {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "execution.default_agent must be included in execution.agents."
                )
            )
        }
        let unavailableStrictAgents = agents.filter {
            !SkillAgentDiscovery.runnableAgents.contains($0)
        }
        if isolation == "strict", !unavailableStrictAgents.isEmpty {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "Strict execution is unavailable for: " +
                        unavailableStrictAgents.map(\.rawValue).joined(separator: ", ") + "."
                )
            )
        }

        if !issues.filter({ $0.severity == .error }).isEmpty {
            throw SkillPackageError.invalidManifest(issues)
        }

        return SkillPackageManifest(
            apiVersion: apiVersion,
            id: id,
            version: version,
            displayName: displayName,
            targets: targets,
            agents: agents,
            defaultAgent: defaultAgent,
            timeoutSeconds: min(max(timeout, 1), 3600),
            isolation: isolation,
            workspaceCheckout: workspaceCheckout,
            workspaceCWD: workspaceCWD,
            workspaceAccess: document.scalar("workspace.access") ?? "read_only",
            shellAccess: document.scalar("workspace.shell") ?? "denied",
            networkAccess: document.scalar("network.access") ?? "denied",
            automationEnabled: document.bool("automation.enabled") ?? false,
            autoApplyTags: document.bool("tags.auto_apply") ?? false,
            contextIncludes: contextIncludes,
            resultSchemaPath: resultSchemaPath,
            presentationPath: presentationPath,
            browserContributionsPath: document.scalar("browser.contributions"),
            browserCompanionPath: {
                guard let value = document.scalar("browser.companion"),
                      value != "optional",
                      value != "none" else {
                    return nil
                }
                return value
            }(),
            adapter: document.scalar("execution.adapter")
        )
    }

    static func validate(at rootURL: URL) -> SkillPackageValidation {
        var issues: [SkillPackageIssue] = []
        let package: SkillPackage
        do {
            package = try load(at: rootURL)
        } catch SkillPackageError.invalidManifest(let parseIssues) {
            return SkillPackageValidation(valid: false, issues: parseIssues)
        } catch {
            return SkillPackageValidation(
                valid: false,
                issues: [
                    SkillPackageIssue(
                        severity: .error,
                        path: "ghpr.skill.yaml",
                        message: error.localizedDescription
                    )
                ]
            )
        }

        var resolvedFiles: [String: URL] = [:]
        func requireFile(_ relativePath: String, message: String) {
            do {
                resolvedFiles[relativePath] = try resolvedPackagePath(
                    relativePath,
                    under: package.rootURL,
                    requireRegularFile: true
                )
            } catch {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: relativePath,
                        message: error is SkillPackageError
                            ? error.localizedDescription
                            : message
                    )
                )
            }
        }
        requireFile("SKILL.md", message: "Required package file is missing.")
        requireFile(
            package.manifest.resultSchemaPath,
            message: "Result schema file is missing."
        )
        requireFile(
            package.manifest.presentationPath,
            message: "Presentation file is missing."
        )
        if let path = package.manifest.browserContributionsPath {
            requireFile(path, message: "Browser contributions file is missing.")
        }
        if let path = package.manifest.browserCompanionPath {
            requireFile(path, message: "Browser companion file is missing.")
        }

        if package.manifest.isolation != "strict" {
            issues.append(
                SkillPackageIssue(
                    severity: .warning,
                    path: "ghpr.skill.yaml",
                    message: "execution.isolation is not strict."
                )
            )
        }
        if package.manifest.workspaceCheckout != "none" {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "workspace.checkout must be 'none' in the strict data-only runtime."
                )
            )
        }
        if package.manifest.workspaceCWD != "run_root" {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "workspace.cwd must be 'run_root'."
                )
            )
        }
        if package.manifest.workspaceAccess != "read_only" {
            issues.append(
                SkillPackageIssue(
                    severity: .warning,
                    path: "ghpr.skill.yaml",
                    message: "The Skill requests writable workspace access."
                )
            )
        }
        if package.manifest.shellAccess != "denied" {
            issues.append(
                SkillPackageIssue(
                    severity: .warning,
                    path: "ghpr.skill.yaml",
                    message: "The Skill requests shell access."
                )
            )
        }
        if package.manifest.networkAccess != "denied" {
            issues.append(
                SkillPackageIssue(
                    severity: .warning,
                    path: "ghpr.skill.yaml",
                    message: "The Skill requests network access."
                )
            )
        }
        if package.manifest.automationEnabled {
            issues.append(
                SkillPackageIssue(
                    severity: .warning,
                    path: "ghpr.skill.yaml",
                    message: "The Skill enables automatic execution."
                )
            )
        }
        if package.manifest.autoApplyTags {
            issues.append(
                SkillPackageIssue(
                    severity: .warning,
                    path: "ghpr.skill.yaml",
                    message: "The Skill automatically applies PR tags."
                )
            )
        }

        if let adapter = package.manifest.adapter {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: "ghpr.skill.yaml",
                    message: "execution.adapter '\(adapter)' is not supported by this ghpr build."
                )
            )
        }

        if let schemaURL = resolvedFiles[package.manifest.resultSchemaPath] {
            do {
                let schemaData = try Data(contentsOf: schemaURL)
                let object = try JSONSerialization.jsonObject(with: schemaData)
                if !(object is [String: Any]) {
                    issues.append(
                        SkillPackageIssue(
                            severity: .error,
                            path: package.manifest.resultSchemaPath,
                            message: "Result schema must be a JSON object."
                        )
                    )
                }
            } catch {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: package.manifest.resultSchemaPath,
                        message: "Result schema is not valid JSON: \(error.localizedDescription)"
                    )
                )
            }
        }

        if let presentationURL = resolvedFiles[package.manifest.presentationPath] {
            validatePresentationContract(
                at: presentationURL,
                relativePath: package.manifest.presentationPath,
                issues: &issues
            )
        }
        if let browserPath = package.manifest.browserContributionsPath,
           let browserURL = resolvedFiles[browserPath] {
            validateBrowserContract(
                at: browserURL,
                relativePath: browserPath,
                issues: &issues
            )
        }

        return SkillPackageValidation(
            valid: !issues.contains(where: { $0.severity == .error }),
            issues: issues
        )
    }

    private static func validatePresentationContract(
        at url: URL,
        relativePath: String,
        issues: inout [SkillPackageIssue]
    ) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: relativePath,
                    message: "Presentation contract is not valid UTF-8."
                )
            )
            return
        }
        let document = SimpleYAMLDocument(text)
        guard document.scalar("api_version") == GHPRContract.presentationVersion else {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: relativePath,
                    message: "Presentation contract must use \(GHPRContract.presentationVersion)."
                )
            )
            return
        }
        let groups = [
            ("summary", SimpleYAMLDocument.records(in: text, section: "summary")),
            ("detail", SimpleYAMLDocument.records(in: text, section: "detail"))
        ]
        if groups.contains(where: { $0.1.isEmpty }) {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: relativePath,
                    message: "Presentation contract requires non-empty summary and detail sections."
                )
            )
        }
        var identifiers = Set<String>()
        for (group, sections) in groups {
            for (index, section) in sections.enumerated() {
                let location = "\(group)[\(index)]"
                guard let id = section["id"], !id.isEmpty else {
                    issues.append(
                        SkillPackageIssue(
                            severity: .error,
                            path: relativePath,
                            message: "\(location) is missing id."
                        )
                    )
                    continue
                }
                if !identifiers.insert(id).inserted {
                    issues.append(
                        SkillPackageIssue(
                            severity: .error,
                            path: relativePath,
                            message: "Presentation section id '\(id)' is duplicated."
                        )
                    )
                }
                guard let type = section["type"],
                      PresentationSectionType(rawValue: type) != nil else {
                    issues.append(
                        SkillPackageIssue(
                            severity: .error,
                            path: relativePath,
                            message: "\(location) uses an unsupported presentation type."
                        )
                    )
                    continue
                }
                if section["value_path"]?.isEmpty != false {
                    issues.append(
                        SkillPackageIssue(
                            severity: .error,
                            path: relativePath,
                            message: "\(location) is missing value_path."
                        )
                    )
                }
            }
        }
    }

    private static func validateBrowserContract(
        at url: URL,
        relativePath: String,
        issues: inout [SkillPackageIssue]
    ) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: relativePath,
                    message: "Browser contract is not valid UTF-8."
                )
            )
            return
        }
        let document = SimpleYAMLDocument(text)
        if document.scalar("api_version") == GHPRContract.browserVersionV2 {
            validateBrowserContractV2(
                document: document,
                text: text,
                relativePath: relativePath,
                issues: &issues
            )
            return
        }
        guard document.scalar("api_version") == GHPRContract.browserVersion else {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: relativePath,
                    message: "Browser contract must use \(GHPRContract.browserVersion)."
                )
            )
            return
        }
        let surfaces = document.list("surfaces")
        if surfaces.isEmpty || surfaces.contains(where: { !$0.hasPrefix("github.") }) {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: relativePath,
                    message: "Browser contract requires at least one github.* surface."
                )
            )
        }
        let contributions = SimpleYAMLDocument.records(
            in: text,
            section: "contributions"
        )
        if contributions.isEmpty {
            issues.append(
                SkillPackageIssue(
                    severity: .error,
                    path: relativePath,
                    message: "Browser contract requires at least one contribution."
                )
            )
        }
        var identifiers = Set<String>()
        for (index, contribution) in contributions.enumerated() {
            let location = "contributions[\(index)]"
            guard let id = contribution["id"], !id.isEmpty else {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: relativePath,
                        message: "\(location) is missing id."
                    )
                )
                continue
            }
            if !identifiers.insert(id).inserted {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: relativePath,
                        message: "Browser contribution id '\(id)' is duplicated."
                    )
                )
            }
            guard let slot = contribution["slot"],
                  BrowserSlot(rawValue: slot) != nil else {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: relativePath,
                        message: "\(location) uses an unsupported Browser slot."
                    )
                )
                continue
            }
            guard let componentType = contribution["component.type"],
                  BrowserComponentType(rawValue: componentType) != nil else {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: relativePath,
                        message: "\(location) uses an unsupported component type."
                    )
                )
                continue
            }
            if let tone = contribution["component.tone"],
               BrowserTone(rawValue: tone) == nil {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: relativePath,
                        message: "\(location) uses an unsupported component tone."
                    )
                )
            }
            if let action = contribution["action.kind"],
               BrowserActionKind(rawValue: action) == nil {
                issues.append(
                    SkillPackageIssue(
                        severity: .error,
                        path: relativePath,
                        message: "\(location) uses an unsupported action kind."
                    )
                )
            }
        }
    }

    private static func validateBrowserContractV2(
        document: SimpleYAMLDocument,
        text: String,
        relativePath: String,
        issues: inout [SkillPackageIssue]
    ) {
        func reject(_ message: String) {
            issues.append(
                SkillPackageIssue(severity: .error, path: relativePath, message: message)
            )
        }

        let allowedRootKeys: Set<String> = ["api_version", "target_kinds", "placements"]
        for key in document.topLevelKeys where !allowedRootKeys.contains(key) {
            reject("Browser contract v2 contains unknown root field '\(key)'.")
        }

        let targetKinds = document.list("target_kinds")
        if targetKinds.isEmpty ||
            targetKinds.contains(where: { BrowserTargetKindV2(rawValue: $0) == nil }) {
            reject("Browser contract v2 target_kinds must be a non-empty list of known target kinds.")
        }

        let placements = SimpleYAMLDocument.records(in: text, section: "placements")
        guard !placements.isEmpty else {
            reject("Browser contract v2 requires at least one placement.")
            return
        }
        let allowedPlacementKeys: Set<String> = [
            "id", "surface", "bind_to", "repeat.source", "view.type"
        ]
        var identifiers = Set<String>()
        for (index, placement) in placements.enumerated() {
            let location = "placements[\(index)]"
            for key in placement.keys where !allowedPlacementKeys.contains(key) {
                reject("\(location) contains unknown field '\(key)'.")
            }
            guard let id = placement["id"], !id.isEmpty else {
                reject("\(location).id must be a non-empty string.")
                continue
            }
            if !identifiers.insert(id).inserted {
                reject("Browser placement id '\(id)' is duplicated.")
            }
            guard let surface = placement["surface"],
                  BrowserSurfaceV2(rawValue: surface) != nil else {
                reject("\(location).surface is not a known Surface ID.")
                continue
            }
            guard let view = placement["view.type"],
                  BrowserViewTypeV2(rawValue: view) != nil else {
                reject("\(location).view.type is not a known view type.")
                continue
            }
            let repeatSource = placement["repeat.source"]
            if let repeatSource,
               !isBrowserV2Binding(repeatSource, prefix: "result.") {
                reject("\(location).repeat.source must be a dotted result.* binding.")
            }
            if let binding = placement["bind_to"] {
                let prefix = repeatSource == nil ? "result." : "item."
                if !isBrowserV2Binding(binding, prefix: prefix) {
                    reject("\(location).bind_to must be a dotted \(prefix)* binding.")
                }
            } else if repeatSource == nil {
                reject("\(location) must declare bind_to or repeat.source.")
            }
        }
    }

    private static func isBrowserV2Binding(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        guard !suffix.isEmpty else { return false }
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        return suffix.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            String($0).range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func browserContractV2(for package: SkillPackage) -> BrowserContractV2? {
        guard let url = package.browserContributionsURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let document = SimpleYAMLDocument(text)
        guard document.scalar("api_version") == GHPRContract.browserVersionV2,
              Set(document.topLevelKeys).isSubset(of: ["api_version", "target_kinds", "placements"]) else {
            return nil
        }
        let targetKinds = document.list("target_kinds").compactMap(BrowserTargetKindV2.init(rawValue:))
        guard !targetKinds.isEmpty,
              targetKinds.count == document.list("target_kinds").count else {
            return nil
        }
        let records = SimpleYAMLDocument.records(in: text, section: "placements")
        let allowedKeys: Set<String> = ["id", "surface", "bind_to", "repeat.source", "view.type"]
        var identifiers = Set<String>()
        let placements = records.compactMap { record -> BrowserPlacementV2? in
            guard Set(record.keys).isSubset(of: allowedKeys),
                  let id = record["id"], !id.isEmpty, identifiers.insert(id).inserted,
                  let surfaceValue = record["surface"],
                  let surface = BrowserSurfaceV2(rawValue: surfaceValue),
                  let viewValue = record["view.type"],
                  let view = BrowserViewTypeV2(rawValue: viewValue) else {
                return nil
            }
            let repeatBinding: BrowserRepeatV2?
            if let source = record["repeat.source"] {
                guard isBrowserV2Binding(source, prefix: "result.") else { return nil }
                repeatBinding = BrowserRepeatV2(source: source)
            } else {
                repeatBinding = nil
            }
            let bindTo = record["bind_to"]
            if let bindTo {
                let prefix = repeatBinding == nil ? "result." : "item."
                guard isBrowserV2Binding(bindTo, prefix: prefix) else { return nil }
            } else if repeatBinding == nil {
                return nil
            }
            return BrowserPlacementV2(
                id: id,
                surface: surface,
                bindTo: bindTo,
                repeatBinding: repeatBinding,
                view: view
            )
        }
        guard !records.isEmpty, placements.count == records.count else { return nil }
        return BrowserContractV2(
            apiVersion: GHPRContract.browserVersionV2,
            targetKinds: targetKinds,
            placements: placements
        )
    }

    static func browserContract(for package: SkillPackage) -> BrowserContract? {
        guard let url = package.browserContributionsURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let document = SimpleYAMLDocument(text)
        guard document.scalar("api_version") == GHPRContract.browserVersion else {
            return nil
        }
        let records = SimpleYAMLDocument.records(in: text, section: "contributions")
        let declarations = records.compactMap { record -> BrowserContributionDeclaration? in
            guard let id = record["id"], !id.isEmpty,
                  let slotValue = record["slot"],
                  let slot = BrowserSlot(rawValue: slotValue),
                  let componentValue = record["component.type"],
                  let componentType = BrowserComponentType(rawValue: componentValue) else {
                return nil
            }
            let tone: BrowserTone
            if let value = record["component.tone"] {
                guard let parsed = BrowserTone(rawValue: value) else { return nil }
                tone = parsed
            } else {
                tone = .neutral
            }
            let action: BrowserAction?
            if let actionValue = record["action.kind"] {
                guard let kind = BrowserActionKind(rawValue: actionValue) else { return nil }
                let tag: PRTag?
                if let value = record["action.tag"] {
                    guard let parsed = PRTag(rawValue: value) else { return nil }
                    tag = parsed
                } else {
                    tag = nil
                }
                action = BrowserAction(
                    kind: kind,
                    skillID: record["action.skill_id"],
                    runID: record["action.run_id"],
                    analysisID: record["action.analysis_id"],
                    tag: tag,
                    event: record["action.event"]
                )
            } else {
                action = nil
            }
            let visibleWhen: [String: String] = Dictionary(
                uniqueKeysWithValues: record.compactMap { entry -> (String, String)? in
                    let (key, value) = entry
                    guard key.hasPrefix("visible_when.") else { return nil }
                    return (String(key.dropFirst("visible_when.".count)), value)
                }
            )
            return BrowserContributionDeclaration(
                id: id,
                slot: slot,
                visibleWhen: visibleWhen,
                component: BrowserComponent(
                    type: componentType,
                    label: record["component.label"],
                    text: record["component.text"],
                    tone: tone,
                    presentationRef: record["component.presentation_ref"]
                ),
                action: action
            )
        }
        guard !records.isEmpty, declarations.count == records.count else {
            return nil
        }
        let surfaces = document.list("surfaces")
        guard !surfaces.isEmpty, surfaces.allSatisfy({ $0.hasPrefix("github.") }) else {
            return nil
        }
        return BrowserContract(
            apiVersion: GHPRContract.browserVersion,
            surfaces: surfaces,
            contributions: declarations
        )
    }

    @discardableResult
    static func scaffold(
        at parentURL: URL,
        id: String,
        displayName: String
    ) throws -> URL {
        guard isSafeIdentifier(id) else {
            throw SkillPackageError.unsafeIdentifier(id)
        }
        let rootURL = parentURL.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: rootURL.path) else {
            throw SkillPackageError.destinationExists(rootURL.path)
        }
        try createPackageDirectories(at: rootURL)

        let manifest = """
        api_version: \(GHPRContract.skillVersion)
        id: \(id)
        version: 1.0.0
        display_name: \(displayName)

        targets:
          - pull_request
          - failed_workflow_run

        execution:
          agents:
            - omp
            - claude_code
          default_agent: omp
          isolation: strict
          timeout_seconds: 600

        workspace:
          checkout: none
          cwd: run_root
          access: read_only
          repository_instructions: ignore
          shell: denied

        network:
          access: denied

        context:
          include:
            - pr_metadata
            - changed_files
            - failed_job_logs

        result:
          schema: schemas/result.schema.json

        presentation:
          file: presentation/presentation.yaml

        browser:
          contributions: browser/contributions.yaml
          companion: optional

        ui:
          context_menu:
            enabled: true
            placement: submenu

        automation:
          enabled: false

        tags:
          auto_apply: false
        """
        try write(manifest, to: rootURL.appendingPathComponent("ghpr.skill.yaml"))
        try write(
            """
            \(generatedMarker)
            # \(displayName)

            Use the context supplied by ghpr. Return only JSON matching `schemas/result.schema.json`.
            Do not modify the checkout, access the network, or execute shell commands.
            """,
            to: rootURL.appendingPathComponent("SKILL.md")
        )
        try write(defaultResultSchema, to: rootURL.appendingPathComponent("schemas/result.schema.json"))
        try write(defaultPresentation, to: rootURL.appendingPathComponent("presentation/presentation.yaml"))
        try write(defaultBrowserContributions(skillID: id), to: rootURL.appendingPathComponent("browser/contributions.yaml"))
        try write(defaultFailedRunFixture, to: rootURL.appendingPathComponent("fixtures/failed-run.json"))
        try write(defaultExpectedResult, to: rootURL.appendingPathComponent("fixtures/expected-result.json"))
        try write(
            """
            # \(displayName)

            Generated by `ghpr skill scaffold`. Validate and preview before installing.
            """,
            to: rootURL.appendingPathComponent("README.md")
        )
        return rootURL
    }

    @discardableResult
    static func migrate(
        sourceURL: URL,
        destinationParentURL: URL,
        id: String
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw SkillPackageError.sourceMissing(sourceURL.path)
        }
        let displayName = sourceURL.lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        let rootURL = try scaffold(at: destinationParentURL, id: id, displayName: displayName)
        let legacyURL = rootURL.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        let copiedURL = legacyURL.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: copiedURL)
        try write(
            """
            \(generatedMarker)
            # \(displayName)

            This managed package preserves the original Skill under `legacy/`.
            Run the preserved instructions using ghpr context and return a Level 0 result:
            `status`, `output`, `artifacts`, and `logs`.
            """,
            to: rootURL.appendingPathComponent("SKILL.md")
        )
        try write(
            levelZeroResultSchema,
            to: rootURL.appendingPathComponent("schemas/result.schema.json")
        )
        try write(
            levelZeroPresentation,
            to: rootURL.appendingPathComponent("presentation/presentation.yaml")
        )
        try write(
            levelZeroExpectedResult,
            to: rootURL.appendingPathComponent("fixtures/expected-result.json")
        )
        return rootURL
    }

    static func enhance(at rootURL: URL, browserSlot: BrowserSlot = .prMergeboxAfter) throws {
        let package = try load(at: rootURL)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("presentation", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("browser", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("fixtures", isDirectory: true),
            withIntermediateDirectories: true
        )
        try write(defaultPresentation, to: package.presentationURL)
        let browser = """
        api_version: \(GHPRContract.browserVersion)
        surfaces:
          - github.pull_request
        contributions:
          - id: \(package.manifest.id).result
            slot: \(browserSlot.rawValue)
            visible_when:
              has_result: true
            component:
              type: result_card
              tone: analysis
              presentation_ref: result.summary
            action:
              kind: open_detail
        """
        try write(browser, to: rootURL.appendingPathComponent("browser/contributions.yaml"))
        if !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("fixtures/expected-result.json").path) {
            try write(defaultExpectedResult, to: rootURL.appendingPathComponent("fixtures/expected-result.json"))
        }
    }

    @discardableResult
    static func prepareNativeEnhancementCopy(
        sourceURL: URL,
        destinationParentURL: URL,
        agents sourceAgents: [SkillAgent],
        displayName requestedDisplayName: String? = nil,
        browserSlot: BrowserSlot = .prMergeboxAfter
    ) throws -> URL {
        let fileManager = FileManager.default
        let canonicalSource = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalSource.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.fileExists(
                atPath: canonicalSource.appendingPathComponent("SKILL.md").path
              ) else {
            throw SkillPackageError.sourceMissing(canonicalSource.path)
        }

        let requestedAgents = Set(sourceAgents)
        let agents = SkillAgentDiscovery.runnableAgents.filter(requestedAgents.contains)
        let resolvedAgents = agents.isEmpty ? SkillAgentDiscovery.runnableAgents : agents
        let defaultAgent = resolvedAgents[0]
        let sourceName = canonicalSource.lastPathComponent
        let words = sourceName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let slug = words.isEmpty ? "skill" : words.joined(separator: "-").lowercased()
        let idPrefix = "user.enhanced.\(defaultAgent.rawValue)."
        let skillID = idPrefix + String(slug.prefix(max(1, 128 - idPrefix.count)))
        let inferredDisplayName = words.isEmpty
            ? "Enhanced Skill"
            : words.joined(separator: " ").capitalized
        let displayName = (requestedDisplayName ?? inferredDisplayName)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: ":", with: " ")
            .replacingOccurrences(of: "#", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let agentRows = resolvedAgents
            .map { "    - \($0.rawValue)" }
            .joined(separator: "\n")

        try fileManager.createDirectory(
            at: destinationParentURL,
            withIntermediateDirectories: true
        )
        let rootURL = destinationParentURL.appendingPathComponent(skillID, isDirectory: true)
        guard !fileManager.fileExists(atPath: rootURL.path) else {
            throw SkillPackageError.destinationExists(rootURL.path)
        }

        do {
            try fileManager.copyItem(at: canonicalSource, to: rootURL)
            try createPackageDirectories(at: rootURL)
            let manifest = """
            # ghpr-managed native Skill copy; SKILL.md is copied unchanged.
            api_version: \(GHPRContract.skillVersion)
            id: \(skillID)
            version: 1.0.0
            display_name: \(displayName.isEmpty ? inferredDisplayName : displayName)

            targets:
              - pull_request
              - failed_workflow_run

            execution:
              agents:
            \(agentRows)
              default_agent: \(defaultAgent.rawValue)
              isolation: strict
              timeout_seconds: 600

            workspace:
              checkout: none
              cwd: run_root
              access: read_only
              repository_instructions: ignore
              shell: denied

            network:
              access: denied

            result:
              schema: schemas/result.schema.json

            presentation:
              file: presentation/presentation.yaml

            browser:
              contributions: browser/contributions.yaml
              companion: optional

            automation:
              enabled: false

            tags:
              auto_apply: false
            """
            try write(manifest, to: rootURL.appendingPathComponent("ghpr.skill.yaml"))

            let schemaURL = rootURL.appendingPathComponent("schemas/result.schema.json")
            if !fileManager.fileExists(atPath: schemaURL.path) {
                try write(
                    """
                    {
                      "$schema": "https://json-schema.org/draft/2020-12/schema",
                      "description": "Pass-through schema for the native Skill result."
                    }
                    """,
                    to: schemaURL
                )
            }
            try write(
                """
                api_version: \(GHPRContract.presentationVersion)
                summary:
                  - id: run_status
                    type: hero
                    title: Status
                    value_path: run.status
                detail:
                  - id: native_result
                    type: markdown
                    title: Result
                    value_path: result
                  - id: run_log
                    type: log
                    title: Run log
                    value_path: run.logs
                """,
                to: rootURL.appendingPathComponent("presentation/presentation.yaml")
            )
            try write(
                """
                api_version: \(GHPRContract.browserVersion)
                surfaces:
                  - github.pull_request
                contributions:
                  - id: \(skillID).run
                    slot: \(browserSlot.rawValue)
                    component:
                      type: action
                      label: Run \(displayName.isEmpty ? inferredDisplayName : displayName)
                      tone: analysis
                    action:
                      kind: run_skill
                      skill_id: \(skillID)
                  - id: \(skillID).result
                    slot: \(browserSlot.rawValue)
                    visible_when:
                      has_result: true
                    component:
                      type: result_card
                      label: \(displayName.isEmpty ? inferredDisplayName : displayName)
                      tone: analysis
                      presentation_ref: run.status
                    action:
                      kind: open_detail
                """,
                to: rootURL.appendingPathComponent("browser/contributions.yaml")
            )
            let fixtureURL = rootURL.appendingPathComponent("fixtures/expected-result.json")
            if !fileManager.fileExists(atPath: fixtureURL.path) {
                try write("{}", to: fixtureURL)
            }
            return rootURL
        } catch {
            try? fileManager.removeItem(at: rootURL)
            throw error
        }
    }

    static func testFixture(at rootURL: URL) throws -> SkillPackageValidation {
        let validation = validate(at: rootURL)
        guard validation.valid else {
            throw SkillPackageError.invalidManifest(validation.issues)
        }
        let package = try load(at: rootURL)
        let schemaURL = try resolvedPackagePath(
            package.manifest.resultSchemaPath,
            under: package.rootURL,
            requireRegularFile: true
        )
        let schemaObject = try jsonObject(at: schemaURL)
        let fixtureURL = try resolvedPackagePath(
            "fixtures/expected-result.json",
            under: package.rootURL,
            requireRegularFile: true
        )
        let fixtureObject = try jsonObject(at: fixtureURL)
        guard let schema = schemaObject as? [String: Any] else {
            throw SkillPackageError.fixtureMismatch("Result schema must be a JSON object.")
        }
        let failures = validateJSONValue(fixtureObject, schema: schema, path: "$")
        guard failures.isEmpty else {
            throw SkillPackageError.fixtureMismatch(
                "Expected result does not match its schema:\n" +
                    failures.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        return validation
    }

    static func validatedResultValue(_ data: Data, for package: SkillPackage) throws -> Any {
        try validatedResultValue(
            data,
            schemaData: Data(contentsOf: package.resultSchemaURL)
        )
    }

    static func parsedResultSchema(_ data: Data) throws -> [String: Any] {
        let schemaObject: Any
        do {
            schemaObject = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SkillPackageError.resultMismatch("Result schema is not valid JSON.")
        }
        guard let schema = schemaObject as? [String: Any] else {
            throw SkillPackageError.resultMismatch("Result schema must be a JSON object.")
        }
        return schema
    }

    static func validatedResultValue(_ data: Data, schemaData: Data) throws -> Any {
        try validatedResultValue(
            data,
            schema: parsedResultSchema(schemaData)
        )
    }

    static func validatedResultValue(
        _ data: Data,
        schema: [String: Any]
    ) throws -> Any {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw SkillPackageError.resultMismatch("Agent result is not valid JSON.")
        }
        let failures = validateJSONValue(value, schema: schema, path: "$")
        guard failures.isEmpty else {
            throw SkillPackageError.resultMismatch(
                "Agent result does not match its schema:\n" +
                    failures.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        return value
    }

    private static func validateJSONValue(
        _ value: Any,
        schema: [String: Any],
        path: String
    ) -> [String] {
        var failures: [String] = []
        let declaredTypes: [String]
        if let type = schema["type"] as? String {
            declaredTypes = [type]
        } else {
            declaredTypes = schema["type"] as? [String] ?? []
        }
        if !declaredTypes.isEmpty,
           !declaredTypes.contains(where: { matchesJSONType(value, type: $0) }) {
            failures.append(
                "\(path) must be \(declaredTypes.joined(separator: " or ")); found \(jsonTypeName(value))."
            )
            return failures
        }

        if let allowed = schema["enum"] as? [Any],
           !allowed.contains(where: { jsonValuesEqual(value, $0) }) {
            failures.append("\(path) is not one of the declared enum values.")
        }

        if let object = value as? [String: Any] {
            let required = schema["required"] as? [String] ?? []
            for key in required where object[key] == nil {
                failures.append("\(path).\(key) is required.")
            }
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for (key, propertySchema) in properties {
                guard let propertyValue = object[key],
                      let childSchema = propertySchema as? [String: Any] else {
                    continue
                }
                failures.append(
                    contentsOf: validateJSONValue(
                        propertyValue,
                        schema: childSchema,
                        path: "\(path).\(key)"
                    )
                )
            }
            let additionalKeys = object.keys.filter { properties[$0] == nil }.sorted()
            if let allowsAdditional = schema["additionalProperties"] as? Bool,
               !allowsAdditional {
                failures.append(contentsOf: additionalKeys.map {
                    "\(path).\($0) is not allowed."
                })
            } else if let additionalSchema = schema["additionalProperties"] as? [String: Any] {
                for key in additionalKeys {
                    failures.append(
                        contentsOf: validateJSONValue(
                            object[key]!,
                            schema: additionalSchema,
                            path: "\(path).\(key)"
                        )
                    )
                }
            }
        }
        if let array = value as? [Any],
           let itemSchema = schema["items"] as? [String: Any] {
            for (index, item) in array.enumerated() {
                failures.append(
                    contentsOf: validateJSONValue(
                        item,
                        schema: itemSchema,
                        path: "\(path)[\(index)]"
                    )
                )
            }
        }

        if let number = value as? NSNumber, !(value is Bool) {
            if let minimum = schema["minimum"] as? NSNumber,
               number.doubleValue < minimum.doubleValue {
                failures.append("\(path) must be at least \(minimum).")
            }
            if let maximum = schema["maximum"] as? NSNumber,
               number.doubleValue > maximum.doubleValue {
                failures.append("\(path) must be at most \(maximum).")
            }
        }
        return failures
    }

    private static func matchesJSONType(_ value: Any, type: String) -> Bool {
        switch type {
        case "null":
            return value is NSNull
        case "object":
            return value is [String: Any]
        case "array":
            return value is [Any]
        case "string":
            return value is String
        case "boolean":
            return value is Bool
        case "number":
            return value is NSNumber && !(value is Bool)
        case "integer":
            guard let number = value as? NSNumber, !(value is Bool) else {
                return false
            }
            return number.doubleValue.isFinite &&
                number.doubleValue.rounded(.towardZero) == number.doubleValue
        default:
            return false
        }
    }

    private static func jsonTypeName(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is Bool { return "boolean" }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        if value is String { return "string" }
        if let number = value as? NSNumber {
            return number.doubleValue.rounded(.towardZero) == number.doubleValue
                ? "integer"
                : "number"
        }
        return "unknown"
    }

    private static func jsonValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if lhs is NSNull, rhs is NSNull { return true }
        if let left = lhs as? Bool, let right = rhs as? Bool {
            return left == right
        }
        if let left = lhs as? String, let right = rhs as? String {
            return left == right
        }
        if let left = lhs as? NSNumber,
           let right = rhs as? NSNumber,
           !(lhs is Bool),
           !(rhs is Bool) {
            return left.doubleValue == right.doubleValue
        }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            return left.count == right.count &&
                zip(left, right).allSatisfy { jsonValuesEqual($0.0, $0.1) }
        }
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            guard left.keys.sorted() == right.keys.sorted() else { return false }
            return left.allSatisfy { key, value in
                right[key].map { jsonValuesEqual(value, $0) } == true
            }
        }
        return false
    }

    @discardableResult
    static func install(
        packageURL: URL,
        skillsRootURL: URL = defaultInstalledSkillsURL()
    ) throws -> URL {
        let validation = validate(at: packageURL)
        guard validation.valid else {
            throw SkillPackageError.invalidManifest(validation.issues)
        }
        let package = try load(at: packageURL)
        try ensureNoEscapingSymlinks(in: package.rootURL)
        try FileManager.default.createDirectory(at: skillsRootURL, withIntermediateDirectories: true)
        let canonicalSkillsRoot = skillsRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = canonicalSkillsRoot.appendingPathComponent(
            package.manifest.id,
            isDirectory: true
        )
        let resolvedDestination = destination.resolvingSymlinksInPath()
        guard contains(destination, in: canonicalSkillsRoot),
              resolvedDestination.path != package.rootURL.path,
              !contains(resolvedDestination, in: package.rootURL),
              !contains(package.rootURL, in: resolvedDestination) else {
            throw SkillPackageError.unsafePath(destination.path)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: package.rootURL, to: destination)
        let installedValidation = validate(at: destination)
        guard installedValidation.valid else {
            try? FileManager.default.removeItem(at: destination)
            throw SkillPackageError.invalidManifest(installedValidation.issues)
        }
        return destination
    }

    @discardableResult
    static func pack(
        packageURL: URL,
        outputURL: URL
    ) throws -> URL {
        let validation = validate(at: packageURL)
        guard validation.valid else {
            throw SkillPackageError.invalidManifest(validation.issues)
        }
        let package = try load(at: packageURL)
        try ensureNoEscapingSymlinks(in: package.rootURL)
        let standardizedOutput = outputURL.standardizedFileURL
        let resolvedOutput = standardizedOutput.resolvingSymlinksInPath()
        guard resolvedOutput.path != package.rootURL.path,
              !contains(resolvedOutput, in: package.rootURL),
              !contains(package.rootURL, in: resolvedOutput) else {
            throw SkillPackageError.unsafePath(outputURL.path)
        }
        if FileManager.default.fileExists(atPath: standardizedOutput.path) {
            try FileManager.default.removeItem(at: standardizedOutput)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            package.rootURL.path,
            standardizedOutput.path
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw SkillPackageError.commandFailed(
                String(data: data, encoding: .utf8) ?? "Unable to pack Skill."
            )
        }
        return standardizedOutput
    }

    static func installedPackages(
        skillsRootURL: URL = defaultInstalledSkillsURL(),
        bundledRootURL: URL? = nil
    ) -> [SkillPackage] {
        var roots: [URL] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: skillsRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            roots.append(contentsOf: entries)
        }
        if let bundledRootURL,
           let entries = try? FileManager.default.contentsOfDirectory(
               at: bundledRootURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ) {
            roots.append(contentsOf: entries)
        }
        var seen = Set<String>()
        return roots.compactMap { try? load(at: $0) }
            .filter { seen.insert($0.manifest.id).inserted }
            .sorted { $0.manifest.displayName < $1.manifest.displayName }
    }

    static func defaultInstalledSkillsURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ghpr/skills", isDirectory: true)
    }

    static func contractExampleJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ContractCapabilities.current)
        return String(decoding: data, as: UTF8.self)
    }

    private static func createPackageDirectories(at rootURL: URL) throws {
        for directory in [
            rootURL,
            rootURL.appendingPathComponent("schemas", isDirectory: true),
            rootURL.appendingPathComponent("presentation", isDirectory: true),
            rootURL.appendingPathComponent("browser", isDirectory: true),
            rootURL.appendingPathComponent("fixtures", isDirectory: true),
            rootURL.appendingPathComponent("tests", isDirectory: true)
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func jsonObject(at url: URL) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard value.count >= 3, value.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let defaultResultSchema = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "required": ["status", "summary"],
      "properties": {
        "status": {
          "type": "string",
          "enum": ["related", "unrelated", "needs_investigation"]
        },
        "summary": { "type": "string" },
        "evidence": {
          "type": "array",
          "items": { "type": "string" }
        }
      },
      "additionalProperties": false
    }
    """

    private static let defaultPresentation = """
    api_version: \(GHPRContract.presentationVersion)
    summary:
      - id: verdict
        type: hero
        value_path: status
      - id: summary
        type: markdown
        value_path: summary
    detail:
      - id: evidence
        type: timeline
        title: Evidence
        value_path: evidence
    """

    private static let levelZeroResultSchema = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "required": ["status", "output", "artifacts", "logs"],
      "properties": {
        "status": {
          "type": "string",
          "enum": ["completed", "failed"]
        },
        "output": { "type": "string" },
        "artifacts": {
          "type": "array",
          "items": {
            "type": "object",
            "required": ["name"],
            "properties": {
              "name": { "type": "string" },
              "path": { "type": ["string", "null"] },
              "media_type": { "type": ["string", "null"] }
            },
            "additionalProperties": false
          }
        },
        "logs": {
          "type": "array",
          "items": { "type": "string" }
        }
      },
      "additionalProperties": false
    }
    """

    private static let levelZeroPresentation = """
    api_version: \(GHPRContract.presentationVersion)
    summary:
      - id: status
        type: hero
        value_path: status
      - id: output
        type: markdown
        value_path: output
    detail:
      - id: artifacts
        type: artifact_list
        title: Artifacts
        value_path: artifacts
      - id: logs
        type: log
        title: Logs
        value_path: logs
    """

    private static let levelZeroExpectedResult = """
    {
      "status": "completed",
      "output": "The preserved Skill completed without structured output.",
      "artifacts": [],
      "logs": []
    }
    """

    private static func defaultBrowserContributions(skillID: String) -> String {
        """
        api_version: \(GHPRContract.browserVersion)
        surfaces:
          - github.pull_request
        contributions:
          - id: \(skillID).action
            slot: pr.header.actions
            visible_when:
              pr_state: open
            component:
              type: action
              label: Run \(skillID)
              tone: analysis
            action:
              kind: run_skill
              skill_id: \(skillID)
          - id: \(skillID).result
            slot: pr.mergebox.after
            visible_when:
              has_result: true
            component:
              type: result_card
              tone: analysis
              presentation_ref: result.summary
            action:
              kind: open_detail
        """
    }

    private static let defaultFailedRunFixture = """
    {
      "repository": "example/service",
      "pr_number": 42,
      "failed_job": "integration-test",
      "logs": "assertion failed: expected 200, received 500",
      "changed_files": ["src/handler.ts", "tests/handler.test.ts"]
    }
    """

    private static let defaultExpectedResult = """
    {
      "status": "needs_investigation",
      "summary": "The fixture does not contain enough history to classify the failure.",
      "evidence": ["One failed run is available."]
    }
    """
}

struct DiscoveredAgentSkill: Codable, Equatable, Identifiable {
    let path: String
    let displayName: String
    let agents: [SkillAgent]
    let isGHPRPackage: Bool

    var id: String { path }
}

enum SkillAgentDiscovery {
    static let supportedAgents: [SkillAgent] = [.claudeCode, .codex, .omp]
    static let runnableAgents: [SkillAgent] = [.omp, .claudeCode, .codex]

    static func roots(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SkillAgent: URL] {
        [
            .claudeCode: homeURL.appendingPathComponent(".claude/skills", isDirectory: true),
            .codex: homeURL.appendingPathComponent(".codex/skills", isDirectory: true),
            .omp: homeURL.appendingPathComponent(".omp/agent/skills", isDirectory: true)
        ]
    }

    static func discover(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [DiscoveredAgentSkill] {
        let fileManager = FileManager.default
        let skillRoots = roots(homeURL: homeURL)
        var discoveredByCanonicalPath: [String: DiscoveredAgentSkill] = [:]

        for agent in supportedAgents {
            guard let root = skillRoots[agent],
                  let entries = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            for entry in entries.sorted(by: { $0.path < $1.path }) {
                guard entry.lastPathComponent != "ghpr-skill-builder",
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      fileManager.fileExists(
                        atPath: entry.appendingPathComponent("SKILL.md").path
                      ) else {
                    continue
                }

                let canonicalURL = entry.standardizedFileURL.resolvingSymlinksInPath()
                let canonicalPath = canonicalURL.path
                let manifestURL = canonicalURL.appendingPathComponent("ghpr.skill.yaml")
                let isGHPRPackage = fileManager.fileExists(atPath: manifestURL.path)
                let displayName = (
                    isGHPRPackage
                        ? try? SkillPackageManager.load(at: canonicalURL).manifest.displayName
                        : nil
                ) ?? canonicalURL.lastPathComponent
                    .replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized

                if let existing = discoveredByCanonicalPath[canonicalPath] {
                    let agents = Set(existing.agents).union([agent])
                    discoveredByCanonicalPath[canonicalPath] = DiscoveredAgentSkill(
                        path: existing.path,
                        displayName: existing.displayName,
                        agents: supportedAgents.filter(agents.contains),
                        isGHPRPackage: existing.isGHPRPackage || isGHPRPackage
                    )
                } else {
                    discoveredByCanonicalPath[canonicalPath] = DiscoveredAgentSkill(
                        path: canonicalPath,
                        displayName: displayName,
                        agents: [agent],
                        isGHPRPackage: isGHPRPackage
                    )
                }
            }
        }

        return discoveredByCanonicalPath.values.sorted {
            let nameOrder = $0.displayName.localizedStandardCompare($1.displayName)
            return nameOrder == .orderedSame ? $0.path < $1.path : nameOrder == .orderedAscending
        }
    }
}


struct CodingAgentIntegrationInstallStatus: Equatable, Identifiable {
    let agent: SkillAgent
    let skillDestination: URL
    let mcpConfigDestination: URL
    let skillInstalled: Bool
    let mcpInstalled: Bool

    var id: String { agent.rawValue }
    var installed: Bool { skillInstalled && mcpInstalled }
}

enum CodingAgentIntegrationError: LocalizedError {
    case missingMCPServer(String)
    case invalidJSONConfig(String)

    var errorDescription: String? {
        switch self {
        case .missingMCPServer(let path):
            return "The bundled ghpr MCP server is missing at \(path)."
        case .invalidJSONConfig(let path):
            return "The coding agent configuration at \(path) is not a valid JSON object."
        }
    }
}

enum CodingAgentIntegrationInstaller {
    private static let managedCodexComment = "# Managed by PRDashboard Coding Agent Integration."

    static func bundledMCPServerURL(bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL else { return nil }
        let url = resourceURL.appendingPathComponent("mcp-ghpr-bundle/index.mjs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static func managedMCPServerURL(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent("com.xiaocang.PRDashboard", isDirectory: true)
            .appendingPathComponent("CodingAgentIntegration", isDirectory: true)
            .appendingPathComponent("mcp-ghpr", isDirectory: true)
            .appendingPathComponent("index.mjs")
    }


    static func skillDestinations(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SkillAgent: URL] {
        SkillAgentDiscovery.roots(homeURL: homeURL).mapValues {
            $0.appendingPathComponent("ghpr-skill-builder", isDirectory: true)
        }
    }

    static func mcpConfigDestinations(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [SkillAgent: URL] {
        [
            .claudeCode: homeURL.appendingPathComponent(".claude.json"),
            .codex: homeURL.appendingPathComponent(".codex/config.toml"),
            .omp: homeURL.appendingPathComponent(".omp/agent/mcp.json")
        ]
    }

    static func statuses(
        sourceMCPServerURL: URL?,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CodingAgentIntegrationInstallStatus] {
        let skillDestinations = skillDestinations(homeURL: homeURL)
        let configDestinations = mcpConfigDestinations(homeURL: homeURL)
        let managedServerURL = managedMCPServerURL(homeURL: homeURL)
        let managedServerIsCurrent: Bool
        if let sourceMCPServerURL,
           let sourceData = try? Data(contentsOf: sourceMCPServerURL),
           let managedData = try? Data(contentsOf: managedServerURL) {
            managedServerIsCurrent = sourceData == managedData
        } else {
            managedServerIsCurrent = false
        }
        return skillDestinations.compactMap { agent, skillDestination in
            guard let configDestination = configDestinations[agent] else { return nil }
            let skillInstalled = FileManager.default.fileExists(
                atPath: skillDestination.appendingPathComponent("SKILL.md").path
            )
            let mcpInstalled = managedServerIsCurrent && isMCPInstalled(
                agent: agent,
                configURL: configDestination,
                serverURL: managedServerURL
            )
            return CodingAgentIntegrationInstallStatus(
                agent: agent,
                skillDestination: skillDestination,
                mcpConfigDestination: configDestination,
                skillInstalled: skillInstalled,
                mcpInstalled: mcpInstalled
            )
        }
        .sorted { $0.agent.rawValue < $1.agent.rawValue }
    }

    static func install(
        sourceSkillURL: URL,
        sourceMCPServerURL: URL,
        agents: Set<SkillAgent>,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> [CodingAgentIntegrationInstallStatus] {
        guard FileManager.default.fileExists(atPath: sourceMCPServerURL.path) else {
            throw CodingAgentIntegrationError.missingMCPServer(sourceMCPServerURL.path)
        }
        let sourceText = try String(contentsOf: sourceSkillURL, encoding: .utf8)
        let managedText = SkillPackageManager.generatedMarker + "\n" + sourceText
        let skillDestinations = skillDestinations(homeURL: homeURL)
        let configDestinations = mcpConfigDestinations(homeURL: homeURL)

        for agent in agents {
            guard let skillDestination = skillDestinations[agent],
                  let configDestination = configDestinations[agent] else {
                continue
            }
            let skillFile = skillDestination.appendingPathComponent("SKILL.md")
            if let existing = try? String(contentsOf: skillFile, encoding: .utf8),
               !existing.contains(SkillPackageManager.generatedMarker) {
                throw SkillPackageError.existingUserSkill(skillFile.path)
            }
            if agent != .codex {
                _ = try readJSONConfig(at: configDestination)
            }
        }
        let managedServerURL = managedMCPServerURL(homeURL: homeURL)
        try writeConfig(Data(contentsOf: sourceMCPServerURL), to: managedServerURL)


        for agent in agents {
            guard let skillDestination = skillDestinations[agent],
                  let configDestination = configDestinations[agent] else {
                continue
            }
            try FileManager.default.createDirectory(
                at: skillDestination,
                withIntermediateDirectories: true
            )
            try managedText.write(
                to: skillDestination.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
            switch agent {
            case .codex:
                try installCodexMCP(configURL: configDestination, serverURL: managedServerURL)
            case .claudeCode, .omp:
                try installJSONMCP(configURL: configDestination, serverURL: managedServerURL)
            case .external:
                continue
            }
        }

        return statuses(sourceMCPServerURL: sourceMCPServerURL, homeURL: homeURL)
            .filter { agents.contains($0.agent) }
    }

    private static func isMCPInstalled(
        agent: SkillAgent,
        configURL: URL,
        serverURL: URL
    ) -> Bool {
        switch agent {
        case .codex:
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else {
                return false
            }
            return text.contains(codexMCPBlock(serverURL: serverURL))
        case .claudeCode, .omp:
            guard let root = try? readJSONConfig(at: configURL),
                  let servers = root["mcpServers"] as? [String: Any],
                  let server = servers["ghpr"] as? [String: Any],
                  server["command"] as? String == "node",
                  let args = server["args"] as? [String] else {
                return false
            }
            return args == [serverURL.path]
        case .external:
            return false
        }
    }

    private static func installJSONMCP(configURL: URL, serverURL: URL) throws {
        var root = try readJSONConfig(at: configURL)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["ghpr"] = [
            "command": "node",
            "args": [serverURL.path]
        ]
        root["mcpServers"] = servers
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try writeConfig(data + Data([0x0A]), to: configURL)
    }

    private static func readJSONConfig(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodingAgentIntegrationError.invalidJSONConfig(url.path)
        }
        return root
    }

    private static func installCodexMCP(configURL: URL, serverURL: URL) throws {
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let lines = existing.components(separatedBy: .newlines)
        var output: [String] = []
        var skippingGhprSection = false
        for line in lines {
            if line == managedCodexComment {
                continue
            }
            if let tableName = tomlTableName(line) {
                let normalized = tableName.replacingOccurrences(of: "\"", with: "")
                skippingGhprSection = normalized == "mcp_servers.ghpr"
                    || normalized.hasPrefix("mcp_servers.ghpr.")
            }
            if !skippingGhprSection {
                output.append(line)
            }
        }
        let retained = output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = [retained, codexMCPBlock(serverURL: serverURL)]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n") + "\n"
        try writeConfig(Data(updated.utf8), to: configURL)
    }

    private static func tomlTableName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["),
              let closingBracket = trimmed.firstIndex(of: "]") else {
            return nil
        }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
    }

    private static func codexMCPBlock(serverURL: URL) -> String {
        """
        \(managedCodexComment)
        [mcp_servers.ghpr]
        command = "node"
        args = ["\(tomlEscaped(serverURL.path))"]
        startup_timeout_sec = 5.0
        """
    }

    private static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func writeConfig(_ data: Data, to url: URL) throws {
        let existingPermissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .posixPermissions
        ]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: existingPermissions ?? 0o600],
            ofItemAtPath: url.path
        )
    }
}

private struct SimpleYAMLDocument {
    private var scalars: [String: String] = [:]
    private(set) var topLevelKeys = Set<String>()
    private var lists: [String: [String]] = [:]

    init(_ text: String) {
        var stack: [(indent: Int, key: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let withoutComment = Self.stripComment(rawLine)
            guard !withoutComment.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            let indent = withoutComment.prefix { $0 == " " }.count
            let content = withoutComment.trimmingCharacters(in: .whitespaces)
            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
            }
            if content.hasPrefix("- ") {
                guard let parent = stack.last else { continue }
                let path = (stack.dropLast().map(\.key) + [parent.key]).joined(separator: ".")
                lists[path, default: []].append(Self.unquote(String(content.dropFirst(2))))
                continue
            }
            guard let colon = content.firstIndex(of: ":") else { continue }
            let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(content[content.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if indent == 0 {
                topLevelKeys.insert(key)
            }
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            if value.isEmpty {
                stack.append((indent, key))
            } else {
                scalars[path] = Self.unquote(value)
            }
        }
    }
    static func records(in text: String, section: String) -> [[String: String]] {
        var records: [[String: String]] = []
        var current: [String: String] = [:]
        var hasCurrent = false
        var sectionIndent: Int?
        var recordIndent: Int?
        var stack: [(indent: Int, key: String)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let withoutComment = stripComment(rawLine)
            guard !withoutComment.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            let indent = withoutComment.prefix { $0 == " " }.count
            let content = withoutComment.trimmingCharacters(in: .whitespaces)

            if sectionIndent == nil {
                if content == "\(section):" {
                    sectionIndent = indent
                }
                continue
            }
            guard let sectionIndent else { continue }
            if indent <= sectionIndent {
                break
            }

            if content.hasPrefix("- "),
               recordIndent == nil || indent == recordIndent {
                if hasCurrent {
                    records.append(current)
                }
                hasCurrent = true
                current = [:]
                recordIndent = indent
                stack.removeAll()
                let inline = String(content.dropFirst(2))
                if let colon = inline.firstIndex(of: ":") {
                    let key = String(inline[..<colon])
                        .trimmingCharacters(in: .whitespaces)
                    let value = String(inline[inline.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                    if !key.isEmpty, !value.isEmpty {
                        current[key] = unquote(value)
                    }
                }
                continue
            }
            guard hasCurrent, !content.hasPrefix("- "),
                  let colon = content.firstIndex(of: ":") else {
                continue
            }
            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
            }
            let key = String(content[..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(content[content.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                stack.append((indent, key))
            } else {
                let path = (stack.map(\.key) + [key]).joined(separator: ".")
                current[path] = unquote(value)
            }
        }
        if hasCurrent {
            records.append(current)
        }
        return records
    }


    func scalar(_ path: String) -> String? {
        scalars[path]
    }

    func list(_ path: String) -> [String] {
        lists[path] ?? []
    }

    func bool(_ path: String) -> Bool? {
        guard let value = scalar(path)?.lowercased() else { return nil }
        if value == "true" { return true }
        if value == "false" { return false }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        var quoted = false
        var output = ""
        for character in line {
            if character == "\"" || character == "'" {
                quoted.toggle()
            }
            if character == "#", !quoted {
                break
            }
            output.append(character)
        }
        return output
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
