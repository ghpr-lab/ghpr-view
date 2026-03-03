import SwiftUI

struct PRSummaryView: View {
    let readyToMerge: Int
    let changesRequested: Int
    let ciFailing: Int
    let ciRunning: Int
    let toReview: Int

    private struct Segment {
        let icon: String
        let color: Color
        let label: String
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        if readyToMerge > 0 {
            result.append(Segment(icon: "checkmark.circle.fill", color: .green, label: "\(readyToMerge) ready to merge"))
        }
        if changesRequested > 0 {
            result.append(Segment(icon: "exclamationmark.triangle.fill", color: .red, label: "\(changesRequested) needs changes"))
        }
        if ciFailing > 0 {
            result.append(Segment(icon: "xmark.circle.fill", color: .red, label: "\(ciFailing) CI failing"))
        }
        if ciRunning > 0 {
            result.append(Segment(icon: "clock.circle.fill", color: .yellow, label: "\(ciRunning) CI running"))
        }
        if toReview > 0 {
            result.append(Segment(icon: "person.crop.circle.badge.clock", color: .orange, label: "\(toReview) to review"))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 4) {
            if segments.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                Text("All clear")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    if index > 0 {
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    Image(systemName: segment.icon)
                        .font(.system(size: 10))
                        .foregroundColor(segment.color)
                    Text(segment.label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
