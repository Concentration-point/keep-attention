import AppKit
import SwiftUI
import KeepAttentionCore

private enum FloatingPanelLayout {
    static let width: CGFloat = 420
    static let collapsedHeight: CGFloat = 96
    static let expandedHeight: CGFloat = 560
}

/// 收起⇄展开的根视图：悬停展开预览，点击钉住（spec §4 触发方式）。
struct IslandRootView: View {
    let model: AppModel
    weak var panel: NSPanel?
    @State private var hovering = false
    @State private var pinned = false
    @State private var showSettings = false
    @State private var waitingIndex = 0
    @State private var selectedHandle: String?
    @State private var dragging = false
    @State private var dragSession: FloatingWindowDragSession?
    @Namespace private var namespace

    private var expanded: Bool { pinned }

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
        return model.pillDisplay
    }

    /// 展开态详情目标：点击选中优先；未选择或 terminal 消失时回退默认展示（issue #13）。
    private var selectedDisplay: AppModel.TerminalDisplay? {
        AppModel.resolveDetailDisplay(
            selectedHandle: selectedHandle,
            displays: model.attentionDisplays,
            fallback: model.attentionDisplays.first ?? panelDisplay
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            if expanded {
                IslandPanel(
                    display: selectedDisplay,
                    terminals: model.attentionDisplays,
                    focusedHandle: model.focusedHandle,
                    selectedHandle: selectedHandle ?? selectedDisplay?.handle,
                    otherWaitingCount: max(model.waitingCount - 1, 0),
                    namespace: namespace,
                    onTogglePin: {
                        withAnimation(spring) { pinned = false }
                    },
                    onCycleWaiting: {
                        let waiting = waitingDisplays
                        guard !waiting.isEmpty else { return }
                        waitingIndex = (waitingIndex + 1) % waiting.count
                        selectedHandle = waiting[waitingIndex].handle
                    },
                    onSelectTerminal: { handle in
                        selectedHandle = handle
                    },
                    onJumpToTerminal: { handle in
                        Task { await model.jumpToTerminal(handle: handle) }
                    },
                    jumpError: model.jumpError
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.5, anchor: .top).combined(with: .opacity),
                    removal: .opacity
                ))
                .gesture(dragGesture)
                .scaleEffect(dragging ? 1.02 : 1)
            } else {
                IslandPill(
                    display: model.pillDisplay,
                    waitingCount: model.waitingCount,
                    totalTerminalCount: model.totalTerminalCount,
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
                .gesture(dragGesture)
                .scaleEffect(dragging ? 1.02 : 1)
            }
        }
        .animation(spring, value: expanded)
        .onHover { hovering = $0 }
        .popover(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .onChange(of: expanded) { _, newValue in
            resizePanel(expanded: newValue, animated: true)
        }
        .onChange(of: model.displays) { _, displays in
            // 选中 terminal 消失（关闭/orca 失败）→ 清空选择，回退默认详情（issue #13）。
            if let handle = selectedHandle, !displays.contains(where: { $0.handle == handle }) {
                selectedHandle = nil
            }
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

    private func resizePanel(expanded: Bool, animated: Bool) {
        guard let panel,
              let visible = (panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let targetHeight = expanded ? FloatingPanelLayout.expandedHeight : FloatingPanelLayout.collapsedHeight
        let frame = FloatingPanelGeometry.framePreservingTopEdge(
            currentFrame: panel.frame,
            targetSize: CGSize(width: FloatingPanelLayout.width, height: targetHeight),
            visibleFrame: visible
        )
        guard panel.frame != frame else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    private var spring: Animation {
        .spring(response: 0.38, dampingFraction: 0.8)
    }

    /// 拖动悬浮窗：位移实时换算为 NSPanel 原点移动（屏幕坐标 y 向上），松手弹回可视区。
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard let panel else { return }
                let currentMouseLocation = NSEvent.mouseLocation
                let session: FloatingWindowDragSession
                if let existing = dragSession {
                    session = existing
                } else {
                    session = FloatingWindowDragSession(
                        windowOrigin: panel.frame.origin,
                        mouseOrigin: FloatingWindowDragSession.mouseOrigin(
                            currentMouseLocation: currentMouseLocation,
                            firstLocalTranslation: value.translation
                        )
                    )
                    dragSession = session
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { dragging = true }
                }
                panel.setFrameOrigin(session.windowOrigin(for: currentMouseLocation))
            }
            .onEnded { _ in
                endDrag()
            }
    }

    private func endDrag() {
        guard let panel else { return }
        dragSession = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragging = false }
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrameOrigin(frame.origin)
        }
    }
}

/// 应用装配：NSApplication + 置顶非激活 NSPanel + 轮询（spec §1/§5）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var poller: Poller?
    private var panel: NSPanel?
    private var eventServer: TraeXEventServer?

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

        let panelHeight = FloatingPanelLayout.collapsedHeight
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: FloatingPanelLayout.width, height: panelHeight),
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

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrame(
                NSRect(
                    x: visible.midX - FloatingPanelLayout.width / 2,
                    y: visible.maxY - panelHeight,
                    width: FloatingPanelLayout.width,
                    height: panelHeight
                ),
                display: false
            )
        }

        let hosting = NSHostingView(rootView: IslandRootView(model: model, panel: panel))
        hosting.setFrameSize(NSSize(width: FloatingPanelLayout.width, height: panelHeight))
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel

        poller.start()

        // TraeX project hook bridge：进程内 unix socket server 接收 helper 转发的 hook 事件。
        // socket 路径优先级：环境变量 > <bundle 相邻项目根>/.trae/keep-attention.env > 默认。
        let socketPath = TraeXHookEnv.loadSocketPath(bundleURL: Bundle.main.bundleURL)
        let server = TraeXEventServer(socketPath: socketPath) { event in
            Task { @MainActor in
                await model.applyTraeXEvent(event)
            }
        }
        do {
            try server.start()
            eventServer = server
        } catch {
            NSLog("keep-attention TraeX socket server 启动失败: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventServer?.stop()
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
