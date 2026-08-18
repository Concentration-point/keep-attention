import SwiftUI
import KeepAttentionCore

/// 极简设置：轮询间隔配置 + 退出（spec §4 设置，硬需求）。
struct SettingsView: View {
    let model: AppModel

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
            Section {
                Button("退出 keep-attention") {
                    NSApp.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 280)
    }

    private var pollIntervalBinding: Binding<Double> {
        Binding(
            get: { model.pollInterval },
            set: { model.pollInterval = $0 }
        )
    }
}
