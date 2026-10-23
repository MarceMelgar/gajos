import AppKit

/// Detecta cuándo se están arrastrando archivos y avisa si se toca una tecla modificadora.
///
/// No usa permisos de accesibilidad: consulta cada 40 ms el estado del botón del mouse,
/// las teclas modificadoras y el portapapeles de arrastre del sistema, que cambia cada vez
/// que empieza un arrastre en cualquier app.
final class DragWatcher: NSObject {
    var onModifierTap: ((Modifier, [URL]) -> Void)?
    var onMouseUp: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var baseline = 0
    private var mouseDown = false
    private var files: [URL]?
    private var lastFlags: NSEvent.ModifierFlags = []

    private static let watchedFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    func start() {
        baseline = dragPasteboard.changeCount
        let timer = Timer(timeInterval: 0.04, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        let flags = NSEvent.modifierFlags.intersection(Self.watchedFlags)

        guard down else {
            if mouseDown {
                mouseDown = false
                files = nil
                onMouseUp?()
            }
            baseline = dragPasteboard.changeCount
            lastFlags = flags
            return
        }

        if !mouseDown {
            mouseDown = true
            lastFlags = flags
        }

        if files == nil, dragPasteboard.changeCount != baseline {
            let urls = dragPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
            files = urls ?? []
            // Las teclas que ya estaban apretadas al empezar el arrastre no cuentan como toque.
            lastFlags = flags
        }

        if let files, !files.isEmpty {
            let pressed = flags.subtracting(lastFlags)
            for modifier in Modifier.allCases where pressed.contains(modifier.flag) {
                onModifierTap?(modifier, files)
            }
        }
        lastFlags = flags
    }
}
