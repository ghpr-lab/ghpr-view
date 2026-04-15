import Foundation

struct AppVersion: Hashable, Comparable, CustomStringConvertible {
    let rawValue: String
    private let numericComponents: [Int]
    private let suffix: String?

    init(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let versionAndSuffix = stripped.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)

        self.rawValue = stripped
        self.numericComponents = versionAndSuffix
            .first?
            .split(separator: ".")
            .compactMap { Int($0) } ?? []
        self.suffix = versionAndSuffix.count > 1 ? String(versionAndSuffix[1]) : nil
    }

    var description: String {
        rawValue
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.numericComponents.count, rhs.numericComponents.count)
        for index in 0..<count {
            let lhsValue = index < lhs.numericComponents.count ? lhs.numericComponents[index] : 0
            let rhsValue = index < rhs.numericComponents.count ? rhs.numericComponents[index] : 0

            if lhsValue != rhsValue {
                return lhsValue < rhsValue
            }
        }

        switch (lhs.suffix, rhs.suffix) {
        case (nil, nil):
            return lhs.rawValue.localizedStandardCompare(rhs.rawValue) == .orderedAscending
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case let (.some(lhsSuffix), .some(rhsSuffix)):
            return lhsSuffix.localizedStandardCompare(rhsSuffix) == .orderedAscending
        }
    }
}

struct ReleaseAsset: Decodable, Equatable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct ReleaseInfo: Decodable, Equatable {
    let tagName: String
    let name: String?
    let body: String
    let publishedAt: Date
    let htmlURL: URL
    let assets: [ReleaseAsset]
    let version: AppVersion

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case publishedAt = "published_at"
        case htmlURL = "html_url"
        case assets
    }

    init(
        tagName: String,
        name: String?,
        body: String,
        publishedAt: Date,
        htmlURL: URL,
        assets: [ReleaseAsset]
    ) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.publishedAt = publishedAt
        self.htmlURL = htmlURL
        self.assets = assets
        self.version = AppVersion(tagName)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decode(String.self, forKey: .body)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        assets = try container.decode([ReleaseAsset].self, forKey: .assets)
        version = AppVersion(tagName)
    }

    var displayVersion: String {
        version.description
    }

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? displayVersion : trimmed
    }

    func preferredZipAsset() throws -> ReleaseAsset {
        let matches = assets.filter { asset in
            asset.name.hasPrefix("PRDashboard-") && asset.name.hasSuffix(".zip")
        }

        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw ReleaseAssetSelectionError.missingZipAsset
        default:
            throw ReleaseAssetSelectionError.multipleZipAssets
        }
    }
}

enum ReleaseAssetSelectionError: LocalizedError, Equatable {
    case missingZipAsset
    case multipleZipAssets

    var errorDescription: String? {
        switch self {
        case .missingZipAsset:
            return "The latest release does not contain a PRDashboard zip asset."
        case .multipleZipAssets:
            return "The latest release contains multiple PRDashboard zip assets."
        }
    }
}

enum InstallEligibility: Equatable {
    case eligible(targetURL: URL)
    case unsupported(reason: String)
}

enum InstallEligibilityResolver {
    static func resolve(
        bundleURL: URL,
        appName: String,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        isBundleWritable: Bool
    ) -> InstallEligibility {
        let standardizedPath = bundleURL.standardizedFileURL.path
        let allowedTargets = [
            "/Applications/\(appName).app",
            homeDirectoryURL.appendingPathComponent("Applications/\(appName).app").standardizedFileURL.path
        ]

        if standardizedPath.contains("/AppTranslocation/") {
            return .unsupported(reason: "This copy is running from an App Translocation path and cannot update itself.")
        }

        if standardizedPath.contains("/Caskroom/") || standardizedPath.contains("/Cellar/") {
            return .unsupported(reason: "Homebrew-managed installs are not updated in place by the app.")
        }

        guard allowedTargets.contains(standardizedPath) else {
            return .unsupported(reason: "Only apps running from /Applications or ~/Applications can update in place.")
        }

        guard isBundleWritable else {
            return .unsupported(reason: "The current app bundle is not writable, so the update cannot be installed automatically.")
        }

        return .eligible(targetURL: URL(fileURLWithPath: standardizedPath))
    }
}

struct UpdateDisplayError {
    let title: String
    let message: String
    let releasePageURL: URL?
    let release: ReleaseInfo?
}

enum UpdateState {
    case idle
    case checking(userInitiated: Bool)
    case upToDate(release: ReleaseInfo)
    case available(release: ReleaseInfo)
    case downloading(release: ReleaseInfo, bytesReceived: Int64, totalBytes: Int64)
    case readyToInstall(release: ReleaseInfo, targetURL: URL)
    case installing(release: ReleaseInfo, targetURL: URL)
    case unsupportedInstallLocation(release: ReleaseInfo, reason: String)
    case error(UpdateDisplayError)

    var releaseInfo: ReleaseInfo? {
        switch self {
        case .idle, .checking, .error:
            return nil
        case let .upToDate(release),
             let .available(release),
             let .downloading(release, _, _),
             let .readyToInstall(release, _),
             let .installing(release, _),
             let .unsupportedInstallLocation(release, _):
            return release
        }
    }
}
