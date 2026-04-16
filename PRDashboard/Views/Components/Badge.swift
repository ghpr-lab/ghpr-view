import SwiftUI

struct Badge: View {
    let count: Int
    var color: Color = .red

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(color)
                .clipShape(Capsule())
                .animation(.spring(response: 0.25), value: count)
        }
    }
}

struct DraftBadge: View {
    var body: some View {
        Text("Draft")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
    }
}

struct MyReviewStatusBadge: View {
    let status: MyReviewStatus

    var body: some View {
        HStack(spacing: 2) {
            Text(emoji)
                .font(.system(size: 11))
            Text(abbreviation)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(textColor)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(backgroundColor)
        .clipShape(Capsule())
    }

    private var emoji: String {
        switch status {
        case .waiting: return "⏳"
        case .changesRequested: return "🟥"
        case .changesResolved: return "🟨"
        case .approved: return "✅"
        }
    }

    private var abbreviation: String {
        switch status {
        case .waiting: return "W"
        case .changesRequested: return "CR-"
        case .changesResolved: return "CR+"
        case .approved: return "A"
        }
    }

    private var textColor: Color {
        switch status {
        case .waiting: return .secondary
        case .changesRequested: return .red
        case .changesResolved: return .orange
        case .approved: return .green
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .waiting: return Color.secondary.opacity(0.15)
        case .changesRequested: return Color.red.opacity(0.15)
        case .changesResolved: return Color.orange.opacity(0.15)
        case .approved: return Color.green.opacity(0.15)
        }
    }
}

struct ApprovalBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(.green)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.green.opacity(0.15))
        .clipShape(Capsule())
    }
}

struct ConflictBadge: View {
    var body: some View {
        Text("Conflict")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.red)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.15))
            .clipShape(Capsule())
    }
}

#if DEBUG
struct Badge_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 10) {
            Badge(count: 5)
            Badge(count: 99)
            Badge(count: 100)
            DraftBadge()
            MyReviewStatusBadge(status: .waiting)
            MyReviewStatusBadge(status: .changesRequested)
            MyReviewStatusBadge(status: .changesResolved)
            MyReviewStatusBadge(status: .approved)
            ApprovalBadge(count: 2)
            ConflictBadge()
        }
        .padding()
    }
}
#endif
