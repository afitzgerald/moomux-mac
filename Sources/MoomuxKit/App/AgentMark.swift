import SwiftUI

/// The agent's company mark. The image is a template so it follows the
/// foreground colour in a toolbar, menu, or popover.
public struct AgentMark: View {
    let agent: String
    let size: CGFloat

    public init(_ agent: String, size: CGFloat = 14) {
        self.agent = agent
        self.size = size
    }

    public var body: some View {
        Image(agent == "Claude" ? "AnthropicMark" : "OpenAIMark", bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
