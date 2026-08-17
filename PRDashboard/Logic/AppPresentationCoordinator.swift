import Foundation

enum AppPresentation: Identifiable {
    case settings
    case jiraSetup(JiraSetupContext)

    var id: UUID {
        switch self {
        case .settings:
            return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .jiraSetup(let context):
            return context.id
        }
    }
}

@MainActor
final class AppPresentationCoordinator {
    typealias PresentationHandler = (AppPresentation) -> Void

    private let presentationHandler: PresentationHandler

    init(presentationHandler: @escaping PresentationHandler) {
        self.presentationHandler = presentationHandler
    }

    func present(_ presentation: AppPresentation) {
        presentationHandler(presentation)
    }
}
