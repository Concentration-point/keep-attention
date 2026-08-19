import SwiftUI
import KeepAttentionCore

/// 设置：轮询间隔 + 通知/控制（issue #34）+ 退出（spec §4 设置，硬需求）。
struct SettingsView: View {
    let model: AppModel
    @StateObject private var controls = NotificationControlsModel()

    var body: some View {
        Form {
            Section {
                Stepper(value: pollIntervalBinding, in: 3...300, step: 1) {
                    Text("轮询间隔：\(Int(model.pollInterval)) 秒")
                }
                Text("每隔该时间采集一次所有 Orca 终端状态。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            NotificationControlsSection(
                model: controls,
                workspaces: knownWorkspaces
            )
            Section {
                Button("退出 keep-attention") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 280)
    }

    /// workspace 列表来自当前 Orca 终端的 repo 名（去重排序；终端未上线时为空）。
    private var knownWorkspaces: [String] {
        Array(Set(model.displays.map(\.repo))).sorted()
    }

    private var pollIntervalBinding: Binding<Double> {
        Binding(
            get: { model.pollInterval },
            set: { model.pollInterval = $0 }
        )
    }
}
