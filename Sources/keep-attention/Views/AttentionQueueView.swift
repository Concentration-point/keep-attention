import SwiftUI
import KeepAttentionCore

struct AttentionQueueView: View {
    let projection: AttentionQueueProjection
    var namespace: Namespace.ID
    let onCollapse: () -> Void
    @State private var evidenceExpanded = false
    @State private var snoozedExpanded = false
    @State private var ambientExpanded = false
    @State private var staleExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if let head = projection.queueHead {
                        RequestCardView(
                            request: head,
                            evidenceExpanded: $evidenceExpanded
                        )
                    } else {
                        quietState
                    }

                    if !projection.queuePreviews.isEmpty {
                        queuePreview
                    }
                    disclosureSection(
                        title: "Snoozed",
                        count: projection.snoozed.count,
                        expanded: $snoozedExpanded,
                        items: projection.snoozed
                    )
                    disclosureSection(
                        title: "State confirmation",
                        count: projection.staleHistory.count,
                        expanded: $staleExpanded,
                        items: projection.staleHistory
                    )
                    AmbientSectionView(
                        entries: projection.ambient,
                        availabilityLabel: projection.ambientAvailabilityLabel,
                        expanded: $ambientExpanded
                    )
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(14)
        .frame(width: 404, height: 540, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(SignalGlass.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(SignalGlass.hairline)
                )
                .matchedGeometryEffect(id: "requestSurface", in: namespace)
        }
        .shadow(color: .black.opacity(0.46), radius: 22, y: 10)
    }

    private var header: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("Attention Queue")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(SignalGlass.primaryText)
                    if projection.requestCount > 0 {
                        Text("\(projection.requestCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(SignalGlass.inkOnSignal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(SignalGlass.amber))
                    }
                }
                Text("Structured obligations, globally sorted")
                    .font(.system(size: 9.5))
                    .foregroundStyle(SignalGlass.secondaryText)
            }
            Spacer()
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(SignalGlassButtonStyle())
            .help("Collapse")
        }
    }

    private var quietState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("No request needs action", systemImage: "checkmark.circle")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(SignalGlass.primaryText)
            Text("Ambient activity stays visible below without being promoted into the queue.")
                .font(.system(size: 11.5))
                .foregroundStyle(SignalGlass.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("not request")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SignalGlass.secondaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(SignalGlass.softFill))
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(SignalGlass.raised)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(SignalGlass.hairline))
        )
    }

    private var queuePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT IN QUEUE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(SignalGlass.secondaryText)
            ForEach(Array(projection.queuePreviews.enumerated()), id: \.offset) { index, request in
                HStack(spacing: 9) {
                    Text("\(index + 2)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(SignalGlass.secondaryText)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.kindLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SignalGlass.primaryText)
                        Text(request.needFromYou)
                            .font(.system(size: 9.5))
                            .foregroundStyle(SignalGlass.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(request.statusLabel)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(SignalGlass.secondaryText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(SignalGlass.softFill.opacity(0.72))
                )
            }
        }
    }

    private func disclosureSection(
        title: String,
        count: Int,
        expanded: Binding<Bool>,
        items: [AttentionRequestCardProjection]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(SignalGlass.primaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.wrappedValue {
                if items.isEmpty {
                    Text("Nothing here.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SignalGlass.secondaryText)
                } else {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.kindLabel)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(SignalGlass.primaryText)
                            Text(item.statusLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(SignalGlass.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(SignalGlass.softFill.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(SignalGlass.hairline))
        )
    }
}
