import UIKit

/// Invisible first responder that turns the iOS keyboard into PC key presses,
/// with a bar of PC-only keys (Ctrl, Alt, Win, Esc, arrows, F-keys…) above it.
final class KeyboardProxyView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((UInt16, [String]) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?

    private lazy var bar = KeyboardAccessoryBar(owner: self)

    // UITextInputTraits: a plain keyboard with no autocorrect.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        let mods = bar.consumeModifiers()
        if mods.isEmpty {
            onText?(text)
            return
        }
        for ch in text {
            if let vk = VK.forCharacter(ch) {
                onKey?(vk, mods)
            } else {
                onText?(String(ch))
            }
        }
    }

    func deleteBackward() {
        onKey?(VK.back, bar.consumeModifiers())
    }

    func pressKey(_ vk: UInt16) {
        onKey?(vk, bar.consumeModifiers())
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onVisibilityChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            bar.clearModifiers()
            onVisibilityChange?(false)
        }
        return ok
    }
}

final class KeyboardAccessoryBar: UIInputView {
    private weak var owner: KeyboardProxyView?
    private var modifierButtons: [String: UIButton] = [:]
    private var active: Set<String> = []

    init(owner: KeyboardProxyView) {
        self.owner = owner
        super.init(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        allowsSelfSizing = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 44) }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let hide = makeButton(title: nil, symbol: "keyboard.chevron.compact.down") { [weak self] in
            _ = self?.owner?.resignFirstResponder()
        }
        hide.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(hide)

        NSLayoutConstraint.activate([
            hide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            hide.widthAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])

        for (title, mod) in [("Ctrl", "ctrl"), ("Alt", "alt"), ("Shift", "shift"), ("Win", "win")] {
            let b = makeButton(title: title, symbol: nil) { [weak self] in self?.toggle(mod) }
            modifierButtons[mod] = b
            stack.addArrangedSubview(b)
        }

        var keys: [(String?, String?, UInt16)] = [
            ("Esc", nil, VK.escape), ("Tab", nil, VK.tab),
            (nil, "arrow.left", VK.left), (nil, "arrow.up", VK.up), (nil, "arrow.down", VK.down), (nil, "arrow.right", VK.right),
            ("Del", nil, VK.delete), ("Home", nil, VK.home), ("End", nil, VK.end), ("PgUp", nil, VK.pageUp), ("PgDn", nil, VK.pageDown),
        ]
        for n in 1...12 {
            let key: (String?, String?, UInt16) = ("F\(n)", nil, VK.f(n))
            keys.append(key)
        }
        keys.append(("PrtSc", nil, VK.printScreen))
        keys.append(("Ins", nil, VK.insert))

        for (title, symbol, vk) in keys {
            stack.addArrangedSubview(makeButton(title: title, symbol: symbol) { [weak self] in self?.owner?.pressKey(vk) })
        }
    }

    private func makeButton(title: String?, symbol: String?, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        if let title = title { b.setTitle(title, for: .normal) }
        if let symbol = symbol { b.setImage(UIImage(systemName: symbol), for: .normal) }
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        b.tintColor = .label
        b.backgroundColor = UIColor.tertiarySystemFill
        b.layer.cornerRadius = 6
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        b.addAction(UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        }, for: .touchUpInside)
        return b
    }

    private func toggle(_ mod: String) {
        if active.contains(mod) { active.remove(mod) } else { active.insert(mod) }
        refresh()
    }

    private func refresh() {
        for (mod, b) in modifierButtons {
            let on = active.contains(mod)
            b.backgroundColor = on ? tintColor : UIColor.tertiarySystemFill
            b.tintColor = on ? .white : .label
        }
    }

    /// Returns the active modifiers and releases them (one-shot, like sticky keys).
    func consumeModifiers() -> [String] {
        let mods = ["ctrl", "alt", "shift", "win"].filter { active.contains($0) }
        if !mods.isEmpty {
            active.removeAll()
            refresh()
        }
        return mods
    }

    func clearModifiers() {
        active.removeAll()
        refresh()
    }
}

extension KeyboardAccessoryBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
