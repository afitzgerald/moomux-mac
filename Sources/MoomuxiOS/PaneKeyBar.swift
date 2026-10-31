import GhosttyTerminal
import UIKit

/// The bar over the phone's keyboard in an attached pane.
///
/// libghostty-spm draws one of its own, but its items are a closed enum and
/// its look is four colours — no room for Moomux's own buttons. The package
/// supports a host drawing its own (`+PublicSticky`, `sendKey`), so this is
/// that: one glass pill, text for the modifiers and icons for the rest, with
/// Ctrl and Alt riding the package's own sticky state so a tap still arms the
/// next key whatever the system keyboard sends.
///
/// Ceiling: there are no punctuation keys (`| ~ /`); they are one tap away on
/// the system keyboard.
@MainActor
final class PaneKeyBar: UIView {
    weak var terminal: UITerminalView? {
        didSet {
            terminal?.setStickyModifierChangeHandler { [weak self] in self?.refresh() }
            refresh()
        }
    }
    var onPhotos: () -> Void = {}
    var onFiles: () -> Void = {}
    var onEditSnippets: () -> Void = {}

    /// Hiding the keyboard swaps it for an empty input view rather than
    /// resigning, so the terminal keeps focus and this bar stays docked at the
    /// bottom of the screen. The terminal's `inputView` reads this.
    var keyboardHidden = false {
        didSet {
            guard keyboardHidden != oldValue else { return }
            if keyboardHidden { closeArrowPad() }
            hideButton?.configuration?.image = Self.keyboardImage(hidden: keyboardHidden)
            hideButton?.accessibilityLabel = keyboardHidden ? "Show Keyboard" : "Hide Keyboard"
            invalidateIntrinsicContentSize()
            terminal?.reloadInputViews()
        }
    }

    private var hideButton: UIButton?
    private var arrowPad: PaneArrowPad?
    private var pendingHide: DispatchWorkItem?
    private let height: CGFloat = 51
    private let pill = UIVisualEffectView(effect: PaneKeyBar.glass())
    private var modifiers: [(TerminalPublicStickyModifier, UIButton)] = []

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 52))
        // Flexible height so the accessory host follows `intrinsicContentSize`.
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        // The pane is always dark whatever the system theme, so the bar is too.
        overrideUserInterfaceStyle = .dark
        build()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not from a nib") }

    override var intrinsicContentSize: CGSize {
        // With no keyboard under it the bar sits at the screen's edge, so it
        // clears the home indicator itself.
        let inset = keyboardHidden ? terminal?.window?.safeAreaInsets.bottom ?? 0 : 0
        return CGSize(width: UIView.noIntrinsicMetric, height: height + max(8, inset))
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        invalidateIntrinsicContentSize()
    }

    // MARK: Layout

    private func build() {
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.clipsToBounds = true
        pill.layer.cornerCurve = .continuous
        pill.layer.cornerRadius = height / 2
        addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.heightAnchor.constraint(equalToConstant: height),
        ])

        let row = UIStackView(arrangedSubviews: [
            modifier("Ctrl", .ctrl),
            key("Esc") { $0.sendKey(.escape) },
            key("Tab") { $0.sendKey(.tab) },
            spacer(),
            icon("dpad", "Arrow Pad") { [weak self] view in self?.toggleArrowPad(in: view) },
            snippetMenu(),
            icon("clipboard", "Paste") {
                // The package's own paste: text, or an image/file as a path,
                // and it commits an open IME composition first.
                $0.resetStickyModifiers()
                $0.paste(nil)
            },
            attachMenu(),
            spacer(),
            modifier("Alt", .alt),
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .center
        row.spacing = 0

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])

        // Outside the scroller: hiding the keyboard must stay reachable
        // however far the row has been scrolled.
        let hide = hideKey()
        let outer = UIStackView(arrangedSubviews: [scroll, hide])
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.alignment = .fill
        outer.spacing = 0
        pill.contentView.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -6),
            outer.topAnchor.constraint(equalTo: pill.contentView.topAnchor),
            outer.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor),
        ])
    }

    /// The pad belongs to the keyboard: it goes when the keyboard does, however
    /// that happened, rather than floating over a pane nobody is typing into.
    func closeArrowPad() {
        arrowPad?.removeFromSuperview()
        arrowPad = nil
    }

    private func toggleArrowPad(in view: UITerminalView) {
        if arrowPad != nil {
            closeArrowPad()
        } else {
            let pad = PaneArrowPad(terminal: view)
            pad.show(in: view)
            arrowPad = pad
        }
    }

    private static func glass() -> UIVisualEffect {
        if #available(iOS 26, *) {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            // Glass takes its colour from what is behind it, which here is the
            // app's light background strip; tint it to the terminal's dark.
            effect.tintColor = UIColor.black.withAlphaComponent(0.7)
            return effect
        }
        return UIBlurEffect(style: .systemThickMaterial)
    }

    // MARK: Buttons

    private func spacer() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 10).isActive = true
        return view
    }

    private func base(_ label: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: .plain())
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = label
        button.tintColor = .label
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: height).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func text(_ title: String, on button: UIButton) {
        var config = button.configuration ?? .plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 7)
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
        ]))
        button.configuration = config
    }

    private func key(_ title: String, _ send: @escaping (UITerminalView) -> Void) -> UIButton {
        let button = base(title) { [weak self] in if let view = self?.terminal { send(view) } }
        text(title, on: button)
        return button
    }

    private func icon(_ symbol: String, _ label: String,
                      _ send: @escaping (UITerminalView) -> Void) -> UIButton {
        let button = base(label) { [weak self] in if let view = self?.terminal { send(view) } }
        var config = button.configuration ?? .plain()
        config.image = UIImage(systemName: symbol,
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        button.configuration = config
        return button
    }

    private func modifier(_ title: String, _ which: TerminalPublicStickyModifier) -> UIButton {
        let button = base(title) { [weak self] in self?.terminal?.toggleStickyModifier(which) }
        text(title, on: button)
        modifiers.append((which, button))
        return button
    }

    private static func keyboardImage(hidden: Bool) -> UIImage? {
        UIImage(systemName: hidden ? "keyboard" : "keyboard.chevron.compact.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 10))
    }

    /// A tap hides or shows the keyboard; a double tap sends Return instead, so
    /// a prompt can be submitted from the bar. The toggle waits out the
    /// double-tap window, or the keyboard would jump on the first tap of two.
    private func hideKey() -> UIButton {
        let button = icon("keyboard.chevron.compact.down", "Hide Keyboard") { _ in }
        hideButton = button
        button.addTarget(self, action: #selector(hideTapped(_:event:)), for: .touchUpInside)
        button.addTarget(self, action: #selector(sendReturn), for: .touchDownRepeat)
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Send Return") { [weak self] _ in
            self?.sendReturn()
            return true
        }]
        return button
    }

    @objc private func hideTapped(_: UIButton, event: UIEvent?) {
        // The second tap of a double lands here too, after `sendReturn`.
        // No touch at all is VoiceOver activating the button.
        guard (event?.allTouches?.first?.tapCount ?? 1) == 1 else { return }
        let hide = DispatchWorkItem { [weak self] in self?.keyboardHidden.toggle() }
        pendingHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: hide)
    }

    @objc private func sendReturn() {
        pendingHide?.cancel()
        pendingHide = nil
        guard let view = terminal else { return }
        // An armed Ctrl would otherwise turn the Return into Ctrl+Return.
        view.resetStickyModifiers()
        view.sendKey(.enter)
    }

    /// A menu rather than a button per snippet: the row is already as wide as
    /// a phone. Return is a keystroke, so it submits even to a program that
    /// treats pasted newlines as text. Built each time it opens, so an edit
    /// in the sheet shows on the next tap.
    private func snippetMenu() -> UIButton {
        let button = icon("bolt", "Snippets") { _ in }
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            let items: [UIMenuElement] = Snippet.saved.map { snippet in
                UIAction(title: snippet.text.trimmingCharacters(in: .whitespaces) + (snippet.submit ? "" : "…")) { [weak self] _ in
                    guard let view = self?.terminal else { return }
                    // An armed Ctrl would otherwise turn the Return into Ctrl+Return.
                    view.resetStickyModifiers()
                    view.paste(text: snippet.text)
                    if snippet.submit { view.sendKey(.enter) }
                }
            }
            let edit = UIAction(title: "Edit Snippets…", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.onEditSnippets()
            }
            done(items + [UIMenu(options: .displayInline, children: [edit])])
        }])
        button.showsMenuAsPrimaryAction = true
        // The menu opens upward; the default would flip the list.
        button.preferredMenuElementOrder = .fixed
        return button
    }

    /// Photos and Files, as in the pane's More menu, one tap closer.
    private func attachMenu() -> UIButton {
        let button = icon("paperclip", "Attach") { _ in }
        button.menu = UIMenu(children: [
            UIAction(title: "Photos", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.onPhotos() },
            UIAction(title: "Files", image: UIImage(systemName: "folder")) { [weak self] _ in self?.onFiles() },
        ])
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
        return button
    }

    /// Ctrl and Alt wear a filled capsule while armed or locked, as the
    /// package's own bar does with its blue.
    private func refresh() {
        for (which, button) in modifiers {
            let state = terminal?.stickyActivation(for: which) ?? .inactive
            var config = button.configuration ?? .plain()
            config.background.backgroundColor = state == .inactive ? .clear : .systemBlue
            config.background.cornerRadius = 16
            config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 6, leading: 2, bottom: 6, trailing: 2)
            config.baseForegroundColor = state == .inactive ? .label : .white
            button.configuration = config
        }
    }
}
