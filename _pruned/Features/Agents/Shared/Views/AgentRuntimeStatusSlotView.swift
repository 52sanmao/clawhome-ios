import SwiftUI

struct AgentRuntimeStatusSlotView: View {
    let title: String

    private var normalizedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Working" : trimmed
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .semibold))
                titleLabel
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.blue.opacity(0.12))
            )

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var titleLabel: some View {
        let baseText = Text(normalizedTitle)
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: 280, alignment: .leading)

        if normalizedTitle.count > 24 {
            baseText.mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.0),
                        .init(color: .white, location: 0.84),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        } else {
            baseText
        }
    }
}
