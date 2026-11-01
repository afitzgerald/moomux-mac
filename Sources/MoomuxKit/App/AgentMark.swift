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

    /// The mark for an agent we have one for, by its name in any case
    /// (`claude` off the wire, `Claude` in the usage line); nil for the rest.
    public static func image(_ agent: String) -> Image? {
        switch agent.lowercased() {
        case "claude": Image("AnthropicMark", bundle: .module).renderingMode(.template)
        case "codex": Image("OpenAIMark", bundle: .module).renderingMode(.template)
        case "opencode": Image("OpencodeMark", bundle: .module).renderingMode(.template)
        case "antigravity": Image("AntigravityMark", bundle: .module).renderingMode(.template)
        default: nil
        }
    }

    public var body: some View {
        (Self.image(agent) ?? Image("OpenAIMark", bundle: .module).renderingMode(.template))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
