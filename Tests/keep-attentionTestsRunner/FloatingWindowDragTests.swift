import CoreGraphics
import Testing
@testable import KeepAttentionCore

@Suite struct FloatingWindowDragTests {
    @Test func derivesInitialMouseOriginFromFirstLocalTranslation() {
        let currentMouse = CGPoint(x: 112, y: 208)
        let translation = CGSize(width: 12, height: -8)

        let origin = FloatingWindowDragSession.mouseOrigin(
            currentMouseLocation: currentMouse,
            firstLocalTranslation: translation
        )

        #expect(origin == CGPoint(x: 100, y: 200))
    }

    @Test func mapsGlobalMouseDeltaToWindowOriginWithoutYInversion() {
        let session = FloatingWindowDragSession(
            windowOrigin: CGPoint(x: 300, y: 400),
            mouseOrigin: CGPoint(x: 100, y: 200)
        )

        #expect(session.windowOrigin(for: CGPoint(x: 115, y: 210)) == CGPoint(x: 315, y: 410))
        #expect(session.windowOrigin(for: CGPoint(x: 90, y: 180)) == CGPoint(x: 290, y: 380))
    }

    @Test func resizesFloatingPanelByPreservingTopEdge() {
        let current = CGRect(x: 100, y: 500, width: 420, height: 96)

        let expanded = FloatingPanelGeometry.framePreservingTopEdge(
            currentFrame: current,
            targetSize: CGSize(width: 420, height: 560),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        #expect(expanded.origin == CGPoint(x: 100, y: 36))
        #expect(expanded.size == CGSize(width: 420, height: 560))
        #expect(expanded.maxY == current.maxY)
    }

    @Test func resizingFloatingPanelClampsIntoVisibleFrame() {
        let current = CGRect(x: 900, y: 760, width: 420, height: 96)

        let expanded = FloatingPanelGeometry.framePreservingTopEdge(
            currentFrame: current,
            targetSize: CGSize(width: 420, height: 560),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        #expect(expanded.origin == CGPoint(x: 580, y: 240))
        #expect(expanded.maxY == 800)
    }
}
