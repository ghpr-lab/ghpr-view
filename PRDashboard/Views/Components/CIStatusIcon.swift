import SwiftUI

struct CIStatusIcon: View {
    let status: CIStatus
    var successCount: Int = 0
    var failureCount: Int = 0
    var pendingCount: Int = 0
    var isRunning: Bool = false
    var workflows: [CIWorkflowInfo] = []

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundColor(iconColor)

                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.35)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: 2)
                }
            }

            // Show counts for failure, pending, or success with workflow info
            if !countText.isEmpty {
                Text(countText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(iconColor)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var iconName: String {
        switch status {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "xmark.circle.fill"
        case .pending:
            return "clock.circle.fill"
        case .expected:
            return "circle.dashed"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch status {
        case .success:
            return .green
        case .failure:
            return .red
        case .pending:
            return .yellow
        case .expected:
            return .secondary
        case .unknown:
            return .orange
        }
    }

    private var countText: String {
        if isHovered {
            return hoverText
        }

        let totalWf = workflows.count
        if totalWf > 0 {
            switch status {
            case .failure:
                let failedWf = workflows.filter { $0.status == .failure }.count
                let totalFailedTasks = workflows.reduce(0) { $0 + $1.failureCount }
                return String(localized: "\(failedWf)/\(totalWf) wf · \(totalFailedTasks)")
            case .pending:
                let doneWf = workflows.filter { $0.status == .success || $0.status == .failure }.count
                return String(localized: "\(doneWf)/\(totalWf) wf")
            case .success:
                return String(localized: "\(totalWf) wf")
            default:
                return ""
            }
        }

        // Fallback to task-level counts when no workflow info
        let total = successCount + failureCount + pendingCount
        if total == 0 { return "" }
        if status == .failure || status == .pending {
            return "\(successCount)/\(total)"
        }
        return ""
    }

    private var hoverText: String {
        let totalWf = workflows.count
        if totalWf > 0 {
            switch status {
            case .failure:
                let failedWf = workflows.filter { $0.status == .failure }.count
                let totalFailedTasks = workflows.reduce(0) { $0 + $1.failureCount }
                if isRunning {
                    return String(localized: "\(failedWf)/\(totalWf) workflows failed, \(totalFailedTasks) tasks, running")
                } else {
                    return String(localized: "\(failedWf)/\(totalWf) workflows failed, \(totalFailedTasks) tasks")
                }
            case .pending:
                let doneWf = workflows.filter { $0.status == .success || $0.status == .failure }.count
                if isRunning {
                    return String(localized: "\(doneWf)/\(totalWf) workflows done, running")
                } else {
                    return String(localized: "\(doneWf)/\(totalWf) workflows done")
                }
            case .success:
                return String(localized: "\(totalWf) workflows passed")
            default:
                return ""
            }
        }

        let total = successCount + failureCount + pendingCount
        if total == 0 { return "" }
        switch status {
        case .failure:
            if isRunning {
                return String(localized: "\(failureCount)/\(total) tasks failed, running")
            } else {
                return String(localized: "\(failureCount)/\(total) tasks failed")
            }
        case .pending:
            if isRunning {
                return String(localized: "\(successCount)/\(total) tasks done, running")
            } else {
                return String(localized: "\(successCount)/\(total) tasks done")
            }
        case .success:
            return String(localized: "\(total) tasks passed")
        default:
            return ""
        }
    }

}

#if DEBUG
struct CIStatusIcon_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 10) {
            HStack {
                CIStatusIcon(status: .success, successCount: 5, failureCount: 0, pendingCount: 0,
                              workflows: [
                                  CIWorkflowInfo(name: "test", isWorkflow: true, successCount: 3, failureCount: 0, pendingCount: 0),
                                  CIWorkflowInfo(name: "build", isWorkflow: true, successCount: 2, failureCount: 0, pendingCount: 0)
                              ])
                Text("Success (2wf)")
            }
            HStack {
                CIStatusIcon(status: .failure, successCount: 3, failureCount: 5, pendingCount: 0, isRunning: true,
                              workflows: [
                                  CIWorkflowInfo(name: "lint", isWorkflow: true, successCount: 1, failureCount: 2, pendingCount: 0),
                                  CIWorkflowInfo(name: "build", isWorkflow: true, successCount: 0, failureCount: 3, pendingCount: 0),
                                  CIWorkflowInfo(name: "test", isWorkflow: true, successCount: 2, failureCount: 0, pendingCount: 0)
                              ])
                Text("Failure running (2/3wf·5)")
            }
            HStack {
                CIStatusIcon(status: .pending, successCount: 2, failureCount: 0, pendingCount: 3, isRunning: true,
                              workflows: [
                                  CIWorkflowInfo(name: "test", isWorkflow: true, successCount: 2, failureCount: 0, pendingCount: 0),
                                  CIWorkflowInfo(name: "deploy", isWorkflow: true, successCount: 0, failureCount: 0, pendingCount: 3)
                              ])
                Text("Pending running (1/2wf)")
            }
            HStack {
                CIStatusIcon(status: .failure, successCount: 3, failureCount: 2, pendingCount: 0)
                Text("Failure fallback (3/5)")
            }
            HStack {
                CIStatusIcon(status: .expected)
                Text("Expected")
            }
        }
        .padding()
    }
}
#endif
