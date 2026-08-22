import AppKit
import SwiftUI
import KeepAttentionCore

private enum FloatingPanelLayout {
    static let width: CGFloat = 420
    /// 窗口固定为展开态高度（不再随收起/展开 resize）：展开动效由 SwiftUI
    /// 单一 spring 驱动，彻底消除 AppKit resize 与 SwiftUI 动画的双时钟频闪。
    static let expandedHeight: CGFloat = 560
}

/// 表面 bounds 的 anchor（在根部收集时才解析，避开 GeometryReader 命名空间冷启动零值问题）。
private struct SurfaceAnchorKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue()
    }
}

/// 把上报的表面 rect 写入窗口容器（AppKit 侧）。
@MainActor
private func updatePanelHitSurface(_ rect: CGRect, panel: NSPanel?) {
    guard let container = panel?.contentView as? PanelPassthroughContentView else { return }
    container.surfaceRect = rect
}

/// 固定尺寸透明窗口的内容容器：仅表面矩形内接收事件，其余区域点击穿透，
/// 使"窗口恒为展开态大小、表面只在视觉上收起"成为可行架构。
final class PanelPassthroughContentView: NSView {
    /// SwiftUI 表面在窗口内的实时矩形（本视图坐标，isFlipped，随动画逐帧更新）。
    var surfaceRect: CGRect = .zero

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 实测：窗口事件分发传入的 contentView hitTest 点为自底向上坐标（isFlipped
        // 不被采纳），而 SwiftUI 上报的 surfaceRect 是左上原点——先翻转到同一直坐标系。
        let flippedPoint = CGPoint(x: point.x, y: bounds.height - point.y)
        guard !surfaceRect.isNull,
              surfaceRect.insetBy(dx: -6, dy: -6).contains(flippedPoint) else { return nil }
        return super.hitTest(point)
    }
}

/// M1 runtime 装配：真实 TraeX hook + Orca ambient 轮询驱动 AttentionQueueModel，
/// 升级只在应用内 banner 呈现（不接系统通知）。
/// 展开/收起 = AttentionIslandSurface 单视图生长（playground 选型 C）。
struct AttentionQueueLiveRootView: View {
    let model: AttentionQueueModel
    weak var panel: NSPanel?
    @State private var expanded = false
    @State private var escalationBanner: AttentionEscalationNotice?
    @State private var dragSession: FloatingWindowDragSession?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                AttentionIslandSurface(
                    projection: model.projection,
                    isExpanded: expanded,
                    onToggle: { expanded.toggle() },
                    expandedContent: {
                        AttentionQueueView(projection: model.projection, actions: liveActions)
                    }
                )
                .gesture(dragGesture)
                .anchorPreference(key: SurfaceAnchorKey.self, value: .bounds) { $0 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(SurfaceAnchorKey.self) { anchor in
                guard let anchor else { return }
                updatePanelHitSurface(proxy[anchor], panel: panel)
            }
            .overlay(alignment: .top) {
                if let escalationBanner {
                    escalationBannerView(escalationBanner)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .task { await pollOrcaForever() }
        .onChange(of: model.lastEscalationNotice) { _, notice in
            presentEscalation(notice)
        }
    }

    /// 队首请求的操作回调：绑定时才渲染 RequestActionsView；head 为 nil 时自动置空。
    private var liveActions: AttentionQueueActions {
        AttentionQueueActions.live(model: model)
    }

    /// 轻量 Orca ambient 轮询：间隔复用既有持久化设置（默认 5s）。
    private func pollOrcaForever() async {
        while !Task.isCancelled {
            await model.pollOrcaOnce()
            try? await Task.sleep(for: .seconds(model.pollInterval))
        }
    }

    /// 应用内升级呈现：短暂 banner，自动淡出；不接 macOS 系统通知。
    private func presentEscalation(_ notice: AttentionEscalationNotice?) {
        guard let notice else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) {
            escalationBanner = notice
        }
        Task {
            try? await Task.sleep(for: .seconds(6))
            guard escalationBanner == notice else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                escalationBanner = nil
            }
        }
    }

    private func escalationBannerView(_ notice: AttentionEscalationNotice) -> some View {
        Label("已升级 · \(notice.kindLabel) 等待你处理", systemImage: "exclamationmark.bubble")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(SignalGlass.inkOnSignal)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(SignalGlass.amber))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .padding(.top, 2)
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
        guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if reduceMotion {
            panel.setFrameOrigin(frame.origin)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                panel.animator().setFrameOrigin(frame.origin)
            }
        }
    }
}

/// 应用装配：NSApplication + 置顶非激活 NSPanel（固定为展开态大小）+ TraeX hook 桥接。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var queueModel: AttentionQueueModel?
    private var panel: NSPanel?
    private var eventServer: TraeXEventServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let environment = ProcessInfo.processInfo.environment
        let defaults = environment["KEEP_ATTENTION_DEFAULTS_SUITE"]
            .flatMap(UserDefaults.init(suiteName:))
            ?? UserDefaults.standard
        let orcaBinary = environment["KEEP_ATTENTION_ORCA_BINARY"]
            ?? OrcaClient.defaultBinaryPath
        let orca = OrcaClient.live(binaryPath: orcaBinary)
        let queueModel = AttentionQueueModel(
            orca: orca,
            jumper: SessionAwareJumper(client: orca),
            defaults: defaults
        )
        self.queueModel = queueModel

        // 窗口恒为展开态大小：收起只是 SwiftUI 表面缩小，透明区域事件穿透，
        // 窗口本体从不 resize → 展开动效单时钟无频闪。
        let panelSize = NSSize(width: FloatingPanelLayout.width, height: FloatingPanelLayout.expandedHeight)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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
                    x: visible.midX - panelSize.width / 2,
                    y: visible.maxY - panelSize.height,
                    width: panelSize.width,
                    height: panelSize.height
                ),
                display: false
            )
        }

        let container = PanelPassthroughContentView(frame: NSRect(origin: .zero, size: panelSize))
        let hosting = NSHostingView(rootView: AttentionQueueLiveRootView(model: queueModel, panel: panel))
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        container.addSubview(hosting)
        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel

        // TraeX project hook bridge：进程内 unix socket server 接收 helper 转发的 hook 事件。
        // socket 路径优先级：环境变量 > <bundle 相邻项目根>/.trae/keep-attention.env > 默认。
        let socketPath = TraeXHookEnv.loadSocketPath(bundleURL: Bundle.main.bundleURL)
        let server = TraeXEventServer(socketPath: socketPath) { event in
            Task { @MainActor in
                queueModel.applyTraeXEvent(event)
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
