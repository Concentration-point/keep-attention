import AppKit
import SwiftUI

/// 收起⇄展开的根视图：悬停展开预览，点击钉住（spec §4 触发方式）。
struct IslandRootView: View {
    let model: AppModel
    @State private var hovering = false
    @State private var pinned = false
    @State private var showSettings = false
    @State private var waitingIndex = 0
    @Namespace private var namespace

    private var expanded: Bool { hovering || pinned }

    /// 等待终端按最久未更新排序（index 0 即最紧急）。
    private var waitingDisplays: [AppModel.TerminalDisplay] {
        model.displays
            .filter { $0.status == .waitingForInput }
            .sorted { ($0.lastOutputAt ?? .distantPast) < ($1.lastOutputAt ?? .distantPast) }
    }

    private var panelDisplay: AppModel.TerminalDisplay? {
        let waiting = waitingDisplays
        if !waiting.isEmpty {
            return waiting[waitingIndex % waiting.count]
        }
        return model.displays.first { $0.handle == model.focusedHandle } ?? model.pillDisplay
    }

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                IslandPanel(
                    display: panelDisplay,
                    otherWaitingCount: max(model.waitingCount - 1, 0),
                    namespace: namespace,
                    onTogglePin: {
                        withAnimation(spring) { pinned = false }
                    },
                    onCycleWaiting: {
                        waitingIndex += 1
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.5, anchor: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                IslandPill(
                    display: model.pillDisplay,
                    waitingCount: model.waitingCount,
                    hasError: model.orcaError != nil,
                    errorMessage: model.orcaError,
                    namespace: namespace,
                    onTap: {
                        withAnimation(spring) { pinned = true }
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .scale(scale: 0.5, anchor: .top).combined(with: .opacity)
                ))
            }
        }
        .animation(spring, value: expanded)
        .onHover { hovering = $0 }
        .popover(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .overlay(alignment: .topTrailing) {
            if expanded {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
                .padding(.trailing, 10)
                .help("设置")
            }
        }
    }

    private var spring: Animation {
        .spring(response: 0.38, dampingFraction: 0.8)
    }
}

/// 应用装配：NSApplication + 置顶非激活 NSPanel + 轮询（spec §1/§5）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var poller: Poller?
    private var panel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let poller = Poller()
        let model = AppModel(
            orca: .live(),
            summarizer: DeepSeekClient(apiKey: DeepSeekClient.apiKeyFromEnvironment()),
            onPollIntervalChanged: { [weak poller] in poller?.reschedule() }
        )
        poller.attach(model)
        self.model = model
        self.poller = poller

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let hosting = NSHostingView(rootView: IslandRootView(model: model))
        hosting.setFrameSize(NSSize(width: 420, height: 320))
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(
                NSRect(x: visible.midX - 210, y: visible.maxY - 320, width: 420, height: 320),
                display: false
            )
        }
        panel.orderFrontRegardless()
        self.panel = panel

        poller.start()
    }
}

@main
enum KeepAttentionMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
