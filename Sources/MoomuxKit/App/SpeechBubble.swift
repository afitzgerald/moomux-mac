import SwiftUI

/// The quip bubble behind the cow's line, shared by both front ends so the
/// tail and the corner radius cannot drift apart. Fill only, no stroke — a
/// border reads as another button rather than a bubble.
public struct SpeechBubble: Shape {
    public var tailSize: CGFloat = 6

    public init(tailSize: CGFloat = 6) { self.tailSize = tailSize }

    public func path(in rect: CGRect) -> Path {
        let bubble = CGRect(x: rect.minX + tailSize, y: rect.minY,
                            width: rect.width - tailSize, height: rect.height)
        var p = Path(roundedRect: bubble, cornerRadius: rect.height / 2)
        let midY = rect.midY
        p.move(to: CGPoint(x: bubble.minX + 1, y: midY - tailSize))
        p.addLine(to: CGPoint(x: rect.minX, y: midY))
        p.addLine(to: CGPoint(x: bubble.minX + 1, y: midY + tailSize))
        p.closeSubpath()
        return p
    }
}
