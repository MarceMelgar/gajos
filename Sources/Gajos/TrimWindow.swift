import AVKit
import AppKit

/// Qué se hace con el tramo elegido.
enum TrimPurpose {
    /// Guardar el tramo como archivo nuevo.
    case trim
    /// Hacer un GIF del tramo (hasta 15 s).
    case gif
}

/// Reproductor con la barra amarilla de recorte de QuickTime, para audio y video.
final class TrimWindowController: NSWindowController, NSWindowDelegate {
    private static var open: Set<TrimWindowController> = []

    private let url: URL
    /// Copia temporal para ver el archivo cuando macOS no lo abre (MKV, WEBM…). Se borra al cerrar.
    private let proxy: URL?
    private let purpose: TrimPurpose
    private let playerView = AVPlayerView()
    private var statusObservation: NSKeyValueObservation?
    private var started = false

    static func present(_ url: URL, isAudio: Bool, proxy: URL? = nil, purpose: TrimPurpose = .trim) {
        let controller = TrimWindowController(url: url, isAudio: isAudio, proxy: proxy, purpose: purpose)
        open.insert(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.waitUntilReady()
    }

    private init(url: URL, isAudio: Bool, proxy: URL?, purpose: TrimPurpose) {
        self.url = url
        self.proxy = proxy
        self.purpose = purpose
        let size = isAudio ? NSSize(width: 640, height: 140) : NSSize(width: 860, height: 520)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = purpose == .gif ? "Tramo para el GIF — \(url.lastPathComponent)" : "Recortar — \(url.lastPathComponent)"
        if purpose == .gif { window.subtitle = "Mové las manijas amarillas: hasta \(Int(VideoFormat.gifMaxSeconds)) segundos" }
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        playerView.controlsStyle = .inline
        playerView.player = AVPlayer(url: proxy ?? url)
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
        // Para el GIF, la selección empieza en los primeros 15 s.
        if purpose == .gif, let item = playerView.player?.currentItem, item.duration.seconds > VideoFormat.gifMaxSeconds {
            item.forwardPlaybackEndTime = CMTime(seconds: VideoFormat.gifMaxSeconds, preferredTimescale: 600)
        }
        playerView.beginTrimming { [weak self] result in
            guard let self else { return }
            guard result == .okButton, let item = self.playerView.player?.currentItem else {
                self.close()
                return
            }
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            var range = CMTimeRange(start: start, end: end)
            let url = self.url, purpose = self.purpose
            self.close()

            var note = ""
            if purpose == .gif, range.duration.seconds > VideoFormat.gifMaxSeconds + 0.05 {
                range = CMTimeRange(start: range.start, duration: CMTime(seconds: VideoFormat.gifMaxSeconds, preferredTimescale: 600))
                note = "\n(el tramo pasaba de \(Int(VideoFormat.gifMaxSeconds)) s: se usaron los primeros \(Int(VideoFormat.gifMaxSeconds)))"
            }
            Toast.show(purpose == .gif ? "Haciendo el GIF…" : "Recortando…", ok: true, silent: true)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let out = purpose == .gif ? try VideoConverter.gif(url, range: range) : try MediaTools.trim(url, range: range)
                    DispatchQueue.main.async { Toast.show("Guardado \(out.lastPathComponent)\(note)", ok: true) }
                } catch {
                    DispatchQueue.main.async { Toast.show(error.localizedDescription, ok: false) }
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        playerView.player = nil
        if let proxy { try? FileManager.default.removeItem(at: proxy.deletingLastPathComponent()) }
        Self.open.remove(self)
    }
}
