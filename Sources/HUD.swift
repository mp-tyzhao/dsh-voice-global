import AppKit

/// 屏幕底部的极简状态条。
///
/// 关键约束：**绝不能抢焦点**——一旦抢走焦点，⌘V 就粘到我们自己身上了。
/// 因此用 nonactivating 面板 + ignoresMouseEvents，并且只用 orderFrontRegardless 显示。
final class HUD {
    private var panel: NSPanel?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var levelBar: LevelBar?
    private var hideWorkItem: DispatchWorkItem?

    private let width: CGFloat = 320
    private let height: CGFloat = 64

    func show(title: String, detail: String, recording: Bool) {
        let panel = ensurePanel()
        titleLabel?.stringValue = title
        detailLabel?.stringValue = detail
        levelBar?.isHidden = !recording
        levelBar?.level = 0
        cancelPendingHide()

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = CGPoint(
                x: frame.midX - width / 2,
                y: frame.minY + 96
            )
            panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func setLevel(_ level: Float) {
        levelBar?.level = level
    }

    /// 显示一个短暂的成功/失败提示后自动隐藏。
    func flash(title: String, detail: String, seconds: Double = 1.6) {
        show(title: title, detail: detail, recording: false)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        cancelPendingHide()
        panel?.orderOut(nil)
    }

    private func cancelPendingHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView(frame: panel.contentView!.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.translatesAutoresizingMaskIntoConstraints = false

        let bar = LevelBar(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(title)
        effect.addSubview(detail)
        effect.addSubview(bar)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            title.topAnchor.constraint(equalTo: effect.topAnchor, constant: 13),

            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),

            bar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            bar.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 7),
            bar.heightAnchor.constraint(equalToConstant: 4),
        ])

        panel.contentView = effect
        self.panel = panel
        titleLabel = title
        detailLabel = detail
        levelBar = bar
        return panel
    }
}

/// 录音电平条：只在录音时显示。
private final class LevelBar: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
        background.fill()

        let clamped = CGFloat(max(0, min(1, level)))
        guard clamped > 0.01 else { return }
        let filled = NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}
