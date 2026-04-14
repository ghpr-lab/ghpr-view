import SwiftUI

struct FirstApprovalBadgeIDPreferenceKey: PreferenceKey {
    static var defaultValue: Int?

    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        value = value ?? nextValue()
    }
}

struct FirstReviewStatusBadgeIDPreferenceKey: PreferenceKey {
    static var defaultValue: Int?

    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        value = value ?? nextValue()
    }
}

private struct OnboardingBubbleModifier: ViewModifier {
    @ObservedObject var manager: OnboardingManager
    let step: OnboardingManager.Step
    let arrow: Edge

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { manager.current == step },
                set: { isPresented in
                    if !isPresented && manager.current == step {
                        manager.dismissCurrentStep()
                    }
                }
            ),
            arrowEdge: arrow
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(step.message)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.progressText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack {
                    Button("Skip") {
                        manager.skip()
                    }

                    Spacer()

                    Button(manager.isLastAvailableStep(step) ? "Got it" : "Next") {
                        manager.next()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 280)
        }
    }
}

extension View {
    func onboardingAnchor(
        _ manager: OnboardingManager,
        step: OnboardingManager.Step,
        arrow: Edge = .bottom
    ) -> some View {
        modifier(OnboardingBubbleModifier(manager: manager, step: step, arrow: arrow))
    }
}
