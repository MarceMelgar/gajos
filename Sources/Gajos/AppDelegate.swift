import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let watcher = DragWatcher()
    private let wheel = WheelController()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        watcher.onModifierTap = { [weak self] modifier, files in
            self?.handleTap(modifier, files: files)
        }
        watcher.onMouseUp = { [weak self] in
            // Un poco de margen para que el gajo termine de recibir los archivos.
            self?.wheel.hide(after: 0.25)
        }
        watcher.start()

        let settings = Settings.shared
        if !settings.hasLaunchedBefore {
            settings.hasLaunchedBefore = true
            openSettings()
        }
    }

    private func handleTap(_ modifier: Modifier, files: [URL]) {
        let settings = Settings.shared
        let kind: WheelKind
        if modifier == settings.conversionModifier {
            kind = .conversion
        } else if modifier == settings.toolsModifier {
            kind = .tools
        } else if modifier == settings.actionsModifier {
            kind = .actions
        } else {
            return
        }
        // Tocar otra vez la misma tecla cierra la rueda; otra tecla la cambia.
        if wheel.isVisible, wheel.kind == kind {
            wheel.hide()
        } else {
            wheel.show(kind, files: files, at: NSEvent.mouseLocation)
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Gajos")

        let menu = NSMenu()
        let hint = NSMenuItem(title: "Arrastrá un archivo y tocá una tecla", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Configuración…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir de Gajos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Configuración de Gajos"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
