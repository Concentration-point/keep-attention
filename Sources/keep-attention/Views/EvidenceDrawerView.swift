import SwiftUI
import KeepAttentionCore

struct EvidenceDrawerView: View {
    let evidence: [AttentionRequestEvidenceProjection]
    var onJump: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SAFE STRUCTURED EVIDENCE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(SignalGlass.secondaryText)

            if evidence.isEmpty {
                Text("No additional structured evidence.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SignalGlass.secondaryText)
            } else {
                ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SignalGlass.blue)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.eventLabel)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(SignalGlass.primaryText)
                            Text("\(item.sourceLabel) · \(item.observedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 9.5))
                                .foregroundStyle(SignalGlass.secondaryText)
                        }
                        Spacer()
                    }
                }
            }

            Button(action: onJump) {
                Label(
                    evidence.first?.jumpReference ?? "Open the matching request",
                    systemImage: "arrow.up.right.square"
                )
            }
            .buttonStyle(SignalGlassButtonStyle())
            .help("Preview placeholder; session-aware jump verification ships separately.")

            Text("Safe reference only · no raw IDs, paths, prompts, or payloads")
                .font(.system(size: 9))
                .foregroundStyle(SignalGlass.secondaryText)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .top) { Rectangle().fill(SignalGlass.hairline).frame(height: 1) }
    }
}
