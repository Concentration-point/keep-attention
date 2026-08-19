import Foundation

public struct TraeXAttentionAdapterResult: Equatable, Sendable {
    public var events: [AttentionRequestEvent]
    public var discovery: TraeXSessionDiscovery?

    public init(events: [AttentionRequestEvent], discovery: TraeXSessionDiscovery? = nil) {
        self.events = events
        self.discovery = discovery
    }
}

public enum TraeXSessionDiscovery: String, Codable, Equatable, Sendable {
    case startBoundaryMissing = "start_boundary_missing"
}

public enum TraeXAttentionAdapter {
    public static func staleAfterRestart(observedAt: Date) -> AttentionRequestEvent {
        .markStaleAfterRestart(observedAt: observedAt)
    }

    public static func adapt(
        _ event: TraeXEvent,
        observedAt: Date,
        sessionIsKnown: Bool
    ) -> TraeXAttentionAdapterResult {
        guard event.isSupported,
              let sessionID = nonEmpty(event.sessionId)
        else {
            return TraeXAttentionAdapterResult(events: [])
        }
        if event.hookEventName == TraeXEvent.sessionEnd {
            return TraeXAttentionAdapterResult(events: [.markStale(
                sessionKey: .traeX(sessionID: sessionID),
                observedAt: observedAt
            )])
        }
        let discovery: TraeXSessionDiscovery? = event.hookEventName != TraeXEvent.sessionStart && !sessionIsKnown
            ? .startBoundaryMissing
            : nil
        guard let turnID = nonEmpty(event.turnId) else {
            return TraeXAttentionAdapterResult(events: [], discovery: discovery)
        }
        let toolUseID = nonEmpty(event.toolUseId)
        let mappedEvent: AttentionRequestEvent?
        switch (event.hookEventName, event.toolName, toolUseID) {
        case (TraeXEvent.permissionRequest, let toolName?, let toolUseID?):
            guard let toolName = nonEmpty(toolName) else {
                return TraeXAttentionAdapterResult(events: [], discovery: discovery)
            }
            mappedEvent = .traeXPermissionRequested(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID,
                toolName: toolName,
                observedAt: observedAt
            )
        case (TraeXEvent.preToolUse, "request_user_input", let toolUseID?):
            mappedEvent = .traeXQuestionOpened(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID,
                observedAt: observedAt
            )
        case (TraeXEvent.postToolUse, "request_user_input", let toolUseID?):
            mappedEvent = .traeXQuestionAnswered(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID,
                observedAt: observedAt
            )
        case (TraeXEvent.postToolUseFailure, "request_user_input", let toolUseID?):
            mappedEvent = .traeXQuestionFailed(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID,
                observedAt: observedAt
            )
        case (TraeXEvent.postToolUse, _, let toolUseID?):
            mappedEvent = .traeXToolCompleted(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID,
                observedAt: observedAt
            )
        case (TraeXEvent.postToolUseFailure, _, let toolUseID?):
            mappedEvent = .traeXQuestionFailed(
                sessionID: sessionID,
                turnID: turnID,
                toolUseID: toolUseID,
                observedAt: observedAt
            )
        default:
            mappedEvent = discovery == nil ? nil : .unclassifiedObserved(
                sessionID: sessionID,
                correlationID: toolUseID ?? turnID,
                eventName: event.hookEventName ?? "unknown",
                observedAt: observedAt
            )
        }
        return TraeXAttentionAdapterResult(
            events: mappedEvent.map { [$0] } ?? [],
            discovery: discovery
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
