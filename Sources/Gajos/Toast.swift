import AppKit

/// Aviso breve junto al cursor con el resultado de la acción.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String, ok: Bool, silent: Bool = false) {
        panel?.orderOut(nil)

        let label = NSTextField(wrappingLabelWithString: (ok ? "✓  " : "⚠︎  ") + text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.preferredMaxLayoutWidth = 320
        label.maximumNumberOfLines = 4
        let textSize = label.fittingSize
        let size = NSSize(width: textSize.width + 28, height: textSize.height + 18)

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.appearance = NSAppearance(named: .darkAqua)
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        label.frame = NSRect(x: 14, y: 9, width: textSize.width, height: textSize.height)
        background.addSubview(label)

        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - size.height - 14)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }

        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = background
        p.orderFrontRegardless()
        panel = p

        if Settings.shared.sound, !silent {
            NSSound(named: ok ? "Pop" : "Basso")?.play()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 1.6 : 3.5)) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
            })
        }
    }
}
