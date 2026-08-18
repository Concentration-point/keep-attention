import CoreGraphics

/// Tracks a floating window drag in global screen coordinates.
public struct FloatingWindowDragSession: Equatable {
    public let windowOrigin: CGPoint
    public let mouseOrigin: CGPoint

    public init(windowOrigin: CGPoint, mouseOrigin: CGPoint) {
        self.windowOrigin = windowOrigin
        self.mouseOrigin = mouseOrigin
    }

    public static func mouseOrigin(
        currentMouseLocation: CGPoint,
        firstLocalTranslation: CGSize
    ) -> CGPoint {
        CGPoint(
            x: currentMouseLocation.x - firstLocalTranslation.width,
            y: currentMouseLocation.y + firstLocalTranslation.height
        )
    }

    public func windowOrigin(for currentMouseLocation: CGPoint) -> CGPoint {
        CGPoint(
            x: windowOrigin.x + currentMouseLocation.x - mouseOrigin.x,
            y: windowOrigin.y + currentMouseLocation.y - mouseOrigin.y
        )
    }
}

public enum FloatingPanelGeometry {
    public static func framePreservingTopEdge(
        currentFrame: CGRect,
        targetSize: CGSize,
        visibleFrame: CGRect
    ) -> CGRect {
        let width = min(targetSize.width, visibleFrame.width)
        let height = min(targetSize.height, visibleFrame.height)
        let maxX = visibleFrame.maxX - width
        let maxY = visibleFrame.maxY - height
        let x = min(max(currentFrame.minX, visibleFrame.minX), maxX)
        let y = min(max(currentFrame.maxY - height, visibleFrame.minY), maxY)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
