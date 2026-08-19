import SwiftUI
import KeepAttentionCore

// issue #34：通知与控制设置（全局 notifications / sound / Reduce Motion / 本地历史清理，
// workspace 级 mute 与 AI 摘要 opt-in）。
//
// 边界：这里只持有状态并持久化到 UserDefaults；升级判定本身在
// KeepAttentionCore.EscalationPolicy（纯函数）。真实 macOS 通知权限/投递、
// 声音播放与系统 Reduce Motion 联动属于人工/真实运行验证缺口，
// 本文件不接入 Poller 主循环。

/// 动效偏好：跟随系统（默认）、强制降低动效、完整动效。
enum MotionPreference: String, Codable, CaseIterable, Identifiable {
    case followSystem
    case alwaysReduced
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followSystem: "跟随系统设置"
        case .alwaysReduced: "始终降低动效"
        case .full: "完整动效"
        }
    }

    var usesReducedMotion: Bool? {
        switch self {
        case .followSystem: nil
        case .alwaysReduced: true
        case .full: false
        }
    }
}

/// 持久化快照（单一 JSON 存 UserDefaults，便于整体读写）。
struct NotificationControlsSnapshot: Codable, Equatable {
    var notificationsEnabled: Bool = true
    var soundEnabled: Bool = false
    var motionPreference: MotionPreference = .followSystem
    var workspaceControls = WorkspaceControlsState()
}

@MainActor
final class NotificationControlsModel: ObservableObject {
    static let storageKey = "notificationControls.v1"

    @Published private(set) var snapshot: NotificationControlsSnapshot {
        didSet { persist() }
    }

    /// "清除本地历史"动作：由 runtime 接线注入（用 LocalHistoryClearance 重建 store）。
    /// 未接线时仅清理本模型持久化的控制状态之外什么都不做，并保留提示文案。
    var onClearLocalHistory: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode(NotificationControlsSnapshot.self, from: data) {
            self.snapshot = stored
        } else {
            self.snapshot = NotificationControlsSnapshot()
        }
    }

    var notificationsEnabled: Bool {
        get { snapshot.notificationsEnabled }
        set { snapshot.notificationsEnabled = newValue }
    }

    var soundEnabled: Bool {
        get { snapshot.soundEnabled }
        set { snapshot.soundEnabled = newValue }
    }

    var motionPreference: MotionPreference {
        get { snapshot.motionPreference }
        set { snapshot.motionPreference = newValue }
    }

    var workspaceControls: WorkspaceControlsState {
        get { snapshot.workspaceControls }
        set { snapshot.workspaceControls = newValue }
    }

    /// AI 摘要全局开关沿用既有约定：配置了 DEEPSEEK_API_KEY 且用户显式开启。
    var globalAISummaryEnabled: Bool {
        DeepSeekClient.apiKeyFromEnvironment() != nil
    }

    func setMuted(_ workspaceID: String, muted: Bool) {
        snapshot.workspaceControls.setMuted(workspaceID, muted: muted)
    }

    func setAISummaryOptIn(_ workspaceID: String, enabled: Bool) {
        snapshot.workspaceControls.setAISummaryOptIn(workspaceID, enabled: enabled)
    }

    func clearLocalHistory() {
        onClearLocalHistory?()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// 设置面板内的通知与控制区块。
struct NotificationControlsSection: View {
    @ObservedObject var model: NotificationControlsModel
    let workspaces: [String]
    @State private var historyClearedNotice: String?

    var body: some View {
        Section("通知") {
            Toggle("启用通知", isOn: $model.notificationsEnabled)
            Toggle("通知声音", isOn: $model.soundEnabled)
            Text("只有高置信的强阻塞请求才会升级打断；同一义务至多一次，60 秒全局节流。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        Section("动效") {
            Picker("动效偏好", selection: $model.motionPreference) {
                ForEach(MotionPreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Section("Workspace 控制") {
            if workspaces.isEmpty {
                Text("暂未发现 workspace（Orca 终端上线后显示）。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(workspaces, id: \.self) { workspace in
                WorkspaceControlRow(
                    workspace: workspace,
                    isMuted: Binding(
                        get: { model.workspaceControls.isMuted(workspace) },
                        set: { model.setMuted(workspace, muted: $0) }
                    ),
                    aiOptIn: Binding(
                        get: { model.workspaceControls.isAISummaryEnabled(workspace, globalAISummaryEnabled: model.globalAISummaryEnabled) },
                        set: { model.setAISummaryOptIn(workspace, enabled: $0) }
                    ),
                    globalAIEnabled: model.globalAISummaryEnabled
                )
            }
        }
        Section("本地数据") {
            Button("清除本地历史") {
                model.clearLocalHistory()
                historyClearedNotice = "已清除（进行中的请求保留）"
            }
            if let notice = historyClearedNotice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkspaceControlRow: View {
    let workspace: String
    @Binding var isMuted: Bool
    @Binding var aiOptIn: Bool
    let globalAIEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("静音 \(workspace)", isOn: $isMuted)
            Toggle("AI 摘要增强", isOn: $aiOptIn)
                .disabled(!globalAIEnabled)
            if !globalAIEnabled {
                Text("未配置 DEEPSEEK_API_KEY，AI 摘要不可用。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
