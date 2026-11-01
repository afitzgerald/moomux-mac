import GhosttyTerminal
import UIKit

/// A floating arrow pad over the pane, opened from `PaneKeyBar`.
///
/// Arrows are what you hold down in an agent TUI — history, menu selection,
/// moving through a prompt — and a row of four small buttons in a scrolling bar
/// is a poor place for them. Each key repeats while held, like a hardware key:
/// once straight away, then after a pause, then steadily.
///
/// Drag the handle along its top edge to move it off whatever it covers; the
/// position is kept across opens and launches. Only the handle drags: the keys
/// fire on touch-down, so a drag that began on one would press it.
///
/// A subview of the terminal and not of the bar: the bar is an accessory view
/// whose host clips and hit-tests to its own bounds, and a button outside them
/// would draw and not respond.
@MainActor
final class PaneArrowPad: UIView {
    private weak var terminal: UITerminalView?
    private let tile: CGFloat = 60
    private let gap: CGFloat = 8
    private let handleHeight: CGFloat = 24
    private static let offsetKey = "arrowPadOffset"
    private var centerX: NSLayoutConstraint?
    private var bottom: NSLayoutConstraint?
    private var panStart = CGPoint.zero

    /// Distance from the default spot — centred, 12pt above the bottom — as
    /// (right, down).
    private var offset: CGPoint {
        get {
            let v = UserDefaults.standard.array(forKey: Self.offsetKey) as? [Double] ?? []
            return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : .zero
        }
        set { UserDefaults.standard.set([Double(newValue.x), Double(newValue.y)], forKey: Self.offsetKey) }
    }

    init(terminal: UITerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        overrideUserInterfaceStyle = .dark

        // Backspace, Up, clear line / Left, Return, Right / Down. The corners
        // under the arrows stay empty, as on the keyboard's own arrow cluster.
        place(0, 0, "delete.left", "Backspace", repeating: true) { $0.sendKey(.backspace) }
        place(1, 0, "arrowtriangle.up.fill", "Up Arrow", repeating: true) { $0.sendKey(.arrowUp) }
        // Ctrl+U: clears the line in a shell and in an agent's prompt.
        place(2, 0, "eraser.line.dashed", "Clear Line", repeating: false) { $0.sendKey(.u, modifiers: .ctrl) }
        place(0, 1, "arrowtriangle.left.fill", "Left Arrow", repeating: true) { $0.sendKey(.arrowLeft) }
        place(1, 1, "return", "Return", repeating: false) { $0.sendKey(.enter) }
        place(2, 1, "arrowtriangle.right.fill", "Right Arrow", repeating: true) { $0.sendKey(.arrowRight) }
        place(1, 2, "arrowtriangle.down.fill", "Down Arrow", repeating: true) { $0.sendKey(.arrowDown) }

        let grip = PadSurface()
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.accessibilityLabel = "Move Arrow Pad"
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        bar.layer.cornerRadius = 2.5
        bar.isUserInteractionEnabled = false
        grip.addSubview(bar)
        grip.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        addSubview(grip)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: tile * 3 + gap * 2),
            heightAnchor.constraint(equalToConstant: handleHeight + tile * 3 + gap * 2),
            grip.leadingAnchor.constraint(equalTo: leadingAnchor),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor),
            grip.topAnchor.constraint(equalTo: topAnchor),
            grip.heightAnchor.constraint(equalToConstant: handleHeight),
            bar.centerXAnchor.constraint(equalTo: grip.centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: grip.centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 40),
            bar.heightAnchor.constraint(equalToConstant: 5),
        ])
    }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        guard let terminal = superview, let centerX, let bottom else { return }
        if pan.state == .began { panStart = CGPoint(x: centerX.constant, y: bottom.constant) }
        let t = pan.translation(in: terminal)
        centerX.constant = panStart.x + t.x
        bottom.constant = panStart.y + t.y
        clamp()
        if pan.state == .ended {
            offset = CGPoint(x: centerX.constant, y: bottom.constant + 12)
        }
    }

    /// Kept inside the terminal: sideways to either edge, and from its bottom
    /// edge up to its top. Also runs on every layout, because the saved
    /// position outlives the terminal's size — one dragged high with the
    /// keyboard hidden would otherwise open off the top once it is showing.
    private func clamp() {
        guard let terminal = superview, let centerX, let bottom else { return }
        let reach = max(0, (terminal.bounds.width - bounds.width) / 2)
        let x = min(max(centerX.constant, -reach), reach)
        let y = min(max(bottom.constant, min(0, bounds.height - terminal.bounds.height)), 0)
        if x != centerX.constant { centerX.constant = x }
        if y != bottom.constant { bottom.constant = y }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clamp()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private func place(_ column: Int, _ row: Int, _ symbol: String, _ label: String,
                       repeating: Bool, _ send: @escaping (UITerminalView) -> Void) {
        let key = PadKey(symbol: symbol, label: label, repeating: repeating) { [weak self] in
            if let view = self?.terminal { send(view) }
        }
        addSubview(key)
        NSLayoutConstraint.activate([
            key.widthAnchor.constraint(equalToConstant: tile),
            key.heightAnchor.constraint(equalToConstant: tile),
            key.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(column) * (tile + gap)),
            key.topAnchor.constraint(equalTo: topAnchor, constant: handleHeight + CGFloat(row) * (tile + gap)),
        ])
    }

    /// Where it lives in `terminal`: centred, just above the bottom edge, which
    /// is the top of the keyboard's bar when that is showing — or wherever it was
    /// last dragged to.
    func show(in terminal: UITerminalView) {
        terminal.addSubview(self)
        let centerX = centerXAnchor.constraint(equalTo: terminal.centerXAnchor, constant: offset.x)
        let bottom = bottomAnchor.constraint(equalTo: terminal.bottomAnchor, constant: offset.y - 12)
        self.centerX = centerX
        self.bottom = bottom
        NSLayoutConstraint.activate([centerX, bottom])
    }
}

/// A part of the pad that keeps its touches from the terminal underneath.
/// The pad is the terminal's subview, so the terminal's own recognizers see
/// every press: a lone tap clicked the pane under the key and toggled the
/// keyboard away, and a quick second press selected a word. UIKit asks the
/// touched view before a recognizer on an ancestor begins, the way a slider
/// keeps a swipe from its superview.
@MainActor
private class PadSurface: UIView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === self
    }
}

/// One glass tile. Fires on touch-down so a tap feels immediate, then repeats
/// while held if it is a key that should.
@MainActor
private final class PadKey: PadSurface {
    private let handler: () -> Void
    private let repeating: Bool
    private var delay: Timer?
    private var ticker: Timer?

    init(symbol: String, label: String, repeating: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        self.repeating = repeating
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .button

        let glass = UIVisualEffectView(effect: Self.glass())
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        glass.layer.cornerCurve = .continuous
        glass.layer.cornerRadius = 22
        glass.isUserInteractionEnabled = false
        addSubview(glass)

        let image = UIImageView(image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)))
        image.translatesAutoresizingMaskIntoConstraints = false
        image.tintColor = .white
        image.contentMode = .center
        image.isUserInteractionEnabled = false
        addSubview(image)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    private static func glass() -> UIVisualEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        effect.tintColor = UIColor.black.withAlphaComponent(0.55)
        return effect
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        handler()
        guard repeating else { return }
        delay = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ticker = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handler() }
                }
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { stop() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { stop() }

    /// A key that goes off screen mid-hold (the pad closed, the pane left) must
    /// not keep firing into the session.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() }
    }

    private func stop() {
        delay?.invalidate()
        ticker?.invalidate()
        delay = nil
        ticker = nil
    }
}
