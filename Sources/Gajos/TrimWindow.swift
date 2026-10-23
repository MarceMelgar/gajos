import AVKit
import AppKit

/// Reproductor con la barra amarilla de recorte de QuickTime, para audio y video.
final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<TrimWindowController> = []

    private let url: URL
    private let playerView = AVPlayerView()
    private var statusObservation: NSKeyValueObservation?
    private var started = false

    static func present(_ url: URL, isAudio: Bool) {
        let controller = TrimWindowController(url: url, isAudio: isAudio)
        open.insert(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.waitUntilReady()
    }

    private init(url: URL, isAudio: Bool) {
        self.url = url
        let size = isAudio ? NSSize(width: 640, height: 140) : NSSize(width: 860, height: 520)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Recortar — \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        playerView.controlsStyle = .inline
        playerView.player = AVPlayer(url: url)
        window.contentView = playerView
    }

    required init?(coder: NSCoder) { fatalError() }

    private func waitUntilReady() {
        statusObservation = playerView.player?.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, !self.started else { return }
                switch item.status {
                case .readyToPlay:
                    self.started = true
                    self.beginTrimming()
                case .failed:
                    self.started = true
                    self.close()
                    Toast.show("macOS no puede abrir \(self.url.lastPathComponent)", ok: false)
                default:
                    break
                }
            }
        }
    }

    private func beginTrimming() {
        statusObservation = nil
        guard playerView.canBeginTrimming else {
            close()
            Toast.show("Este archivo no se puede recortar", ok: false)
            return
        }
        playerView.beginTrimming { [weak self] result in
            guard let self else { return }
            guard result == .okButton, let item = self.playerView.player?.currentItem else {
                self.close()
                return
            }
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            let range = CMTimeRange(start: start, end: end)
            let url = self.url
            self.close()

            Toast.show("Recortando…", ok: true, silent: true)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let out = try MediaTools.trim(url, range: range)
                    DispatchQueue.main.async { Toast.show("Guardado \(out.lastPathComponent)", ok: true) }
                } catch {
                    DispatchQueue.main.async { Toast.show(error.localizedDescription, ok: false) }
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.open.remove(self)
    }
}
