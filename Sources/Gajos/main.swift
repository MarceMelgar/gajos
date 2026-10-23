import AppKit

// Modo de prueba sin interfaz: `Gajos --selftest <carpeta>` o `Gajos --snapshot <carpeta>`.
if SelfTest.handle(CommandLine.arguments) { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
