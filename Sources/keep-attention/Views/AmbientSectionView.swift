import SwiftUI
import KeepAttentionCore

struct AmbientSectionView: View {
    let entries: [AmbientEntryProjection]
    var availabilityLabel: String?
    @Binding var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("Ambient")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("not request")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SignalGlass.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(SignalGlass.softFill))
                    Spacer()
                    Text("\(entries.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .foregroundStyle(SignalGlass.primaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let availabilityLabel {
                Label(availabilityLabel, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(SignalGlass.amber)
            }

            if expanded {
                VStack(spacing: 5) {
                    if entries.isEmpty {
                        Text("No ambient sessions detected.")
                            .font(.system(size: 11))
                            .foregroundStyle(SignalGlass.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        ambientRow(entry)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(SignalGlass.softFill.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(SignalGlass.hairline))
        )
    }

    private func ambientRow(_ entry: AmbientEntryProjection) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(entry.activityLabel == "Active" ? SignalGlass.blue : SignalGlass.quiet)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SignalGlass.primaryText)
                    .lineLimit(1)
                Text("\(entry.activityLabel) · \(entry.connectionLabel)")
                    .font(.system(size: 9))
                    .foregroundStyle(SignalGlass.secondaryText)
            }
            Spacer()
            if entry.coverageLabel == "coverage gap" {
                Text("coverage gap")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(SignalGlass.amber)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(SignalGlass.amberSoft))
            }
        }
        .padding(.vertical, 3)
    }
}
