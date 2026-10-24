import AppKit
import SwiftUI

enum WheelKind {
    case conversion, tools, actions
}

struct Segment {
    let title: String
    var symbol: String? = nil
    var subtitle: String? = nil
    var enabled = true
    /// Si es true, la tarea corre fuera del hilo principal (conversiones, ZIP).
    var background = false
    /// Aviso al empezar, para tareas que pueden tardar (videos).
    var startMessage: String? = nil
    /// Devuelve el mensaje para mostrar al terminar, o nil para no mostrar nada.
    let perform: ([URL]) throws -> String?
}

enum Wheels {
    static func segments(for kind: WheelKind, files: [URL]) -> [Segment] {
        switch kind {
        case .conversion: return conversion(for: files)
        case .tools: return tools(for: files)
        case .actions: return actions()
        }
    }

    /// Comprimir, recortar y quitar metadatos, según el tipo del primer archivo.
    private static func tools(for files: [URL]) -> [Segment] {
        guard let kind = files.first.flatMap(MediaKind.of) else { return [] }

        // Abre una ventana para elegir por calidad o por tamaño final (una sola para todos los archivos).
        let compress = Segment(title: "Comprimir", symbol: "arrow.down.right.and.arrow.up.left") { urls in
            let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) archivos"
            EditorWindow.present(title: "Comprimir — \(title)", size: NSSize(width: 440, height: 340)) { close in
                CompressToolView(files: urls, close: close)
            }
            return nil
        }

        let crop = Segment(title: "Recortar", symbol: kind == .image ? "crop" : "timeline.selection",
                           background: true) { urls in
            // Una ventana por archivo, hasta 5 a la vez.
            for url in urls.prefix(5) {
                if kind == .image {
                    DispatchQueue.main.async {
                        do { try CropWindowController.present(url) }
                        catch { Toast.show(error.localizedDescription, ok: false) }
                    }
                    continue
                }
                // MKV, WEBM, OPUS…: se prepara una copia que macOS pueda reproducir para elegir el tramo.
                var proxy: URL?
                if MediaTools.needsPreviewCopy(url) {
                    DispatchQueue.main.async { Toast.show("Preparando \(url.lastPathComponent)…", ok: true, silent: true) }
                    proxy = try MediaTools.makePreviewCopy(url, isAudio: kind == .audio)
                }
                DispatchQueue.main.async {
                    TrimWindowController.present(url, isAudio: kind == .audio, proxy: proxy)
                }
            }
            return nil
        }

        let strip = Segment(title: "Metadatos", symbol: "tag", subtitle: "quitar", background: true) { urls in
            try eachFile(urls) { url in
                kind == .image ? try ImageTools.stripMetadata(url) : try MediaTools.stripMetadata(url)
            }
        }

        // Fotos y capturas tienen la rueda completa; PDF, audio y video, las tres básicas.
        let isPDF = files.first?.pathExtension.lowercased() == "pdf"
        if kind == .video {
            // La ventana de Fondo con un cuadro del video como vista previa.
            let background = Segment(title: "Fondo", symbol: "photo", subtitle: "agregar", background: true) { urls in
                for url in urls.prefix(5) {
                    // MKV, WEBM, AVI…: se trabaja sobre una copia en MP4 y el resultado queda junto al original.
                    var copy: URL?
                    if MediaTools.needsPreviewCopy(url) {
                        DispatchQueue.main.async { Toast.show("Preparando \(url.lastPathComponent)…", ok: true, silent: true) }
                        copy = try VideoBackground.playableCopy(url)
                    }
                    let preview = try VideoBackground.previewFrame(copy ?? url)
                    let frame = EditableImage(frame: preview.full, url: url)
                    DispatchQueue.main.async {
                        EditorWindow.present(title: "Agregar fondo — \(url.lastPathComponent)") { close in
                            BackgroundToolView(image: frame, isVideo: true, videoCopy: copy, close: close)
                        }
                    }
                }
                return nil
            }
            return [compress, crop, strip, background]
        }
        guard kind == .image, !isPDF else { return [compress, crop, strip] }

        let edit = editorSegment("Editar", "slider.horizontal.3", window: "Editar") { image, close in
            EditToolView(image: image, close: close)
        }
        let annotate = editorSegment("Anotar", "pencil.tip.crop.circle", window: "Anotar") { image, close in
            AnnotateToolView(image: image, close: close)
        }
        let background = editorSegment("Fondo", "photo", subtitle: "agregar", window: "Agregar fondo") { image, close in
            BackgroundToolView(image: image, close: close)
        }
        let redact = editorSegment("Tachar", "eye.slash", window: "Tachar") { image, close in
            RedactToolView(image: image, close: close)
        }
        // Mismo orden que las agujas del reloj desde arriba.
        return [compress, strip, edit, annotate, background, crop, redact]
    }

    /// Gajo que abre una ventana de edición por archivo (hasta 5 a la vez).
    private static func editorSegment<V: View>(_ title: String, _ symbol: String, subtitle: String? = nil, window: String,
                                               _ view: @escaping (EditableImage, @escaping () -> Void) -> V) -> Segment {
        // La imagen se carga en segundo plano (las fotos grandes tardan) y la ventana se abre en el hilo principal.
        Segment(title: title, symbol: symbol, subtitle: subtitle, background: true) { urls in
            for url in urls.prefix(5) {
                let image = try EditableImage.load(url)
                DispatchQueue.main.async {
                    EditorWindow.present(title: "\(window) — \(url.lastPathComponent)") { close in view(image, close) }
                }
            }
            return nil
        }
    }

    /// Aplica la herramienta a cada archivo y junta los mensajes. Solo falla si fallan todos.
    private static func eachFile(_ urls: [URL], _ work: (URL) throws -> String) throws -> String {
        var messages: [String] = []
        var firstError: Error?
        for url in urls {
            do { messages.append(try work(url)) }
            catch { firstError = firstError ?? error }
        }
        if messages.isEmpty, let firstError { throw firstError }
        var text = messages.count <= 3 ? messages.joined(separator: "\n") : "\(messages.count) archivos listos"
        if let firstError { text += "\n(\(firstError.localizedDescription))" }
        return text
    }

    /// Las opciones dependen del tipo del primer archivo: imagen, audio o video.
    private static func conversion(for files: [URL]) -> [Segment] {
        if files.first?.pathExtension.lowercased() == "pdf" {
            return PDFFormat.allCases.map { format in
                Segment(title: format.title, subtitle: format.subtitle, background: true) { urls in
                    try eachFile(urls) { try PDFConverter.convert($0, to: format) }
                }
            }
        }
        switch files.first.flatMap(MediaKind.of) {
        case .image:
            let quality = Settings.shared.quality
            return ImageFormat.allCases.map { format in
                let available = format != .webp || ImageConverter.cwebpPath != nil
                return conversionSegment(format.title, subtitle: available ? nil : "falta cwebp", enabled: available) {
                    try ImageConverter.convert($0, to: format, quality: quality)
                }
            }
        case .audio:
            return AudioFormat.allCases.map { format in
                conversionSegment(format.title, subtitle: format.isAvailable ? format.subtitle : "falta ffmpeg",
                                  enabled: format.isAvailable) {
                    try AudioConverter.convert($0, to: format)
                }
            }
        case .video:
            return VideoFormat.allCases.map { format in
                format == .gif ? gifSegment() : conversionSegment(format.title, subtitle: format.isAvailable ? format.subtitle : "falta ffmpeg",
                                  enabled: format.isAvailable, startMessage: "Convirtiendo video a \(format.title)…") {
                    try VideoConverter.convert($0, to: format)
                }
            }
        case nil:
            return []
        }
    }

    /// GIF: abre la barra de recorte para elegir el tramo (hasta 15 s) antes de hacerlo.
    private static func gifSegment() -> Segment {
        Segment(title: VideoFormat.gif.title, subtitle: "elegí el tramo", background: true) { urls in
            for url in urls.prefix(5) {
                var proxy: URL?
                if MediaTools.needsPreviewCopy(url) {
                    DispatchQueue.main.async { Toast.show("Preparando \(url.lastPathComponent)…", ok: true, silent: true) }
                    proxy = try MediaTools.makePreviewCopy(url, isAudio: false)
                }
                DispatchQueue.main.async {
                    TrimWindowController.present(url, isAudio: false, proxy: proxy, purpose: .gif)
                }
            }
            return nil
        }
    }

    private static func conversionSegment(_ title: String, subtitle: String?, enabled: Bool,
                                          startMessage: String? = nil,
                                          convert: @escaping (URL) throws -> [URL]) -> Segment {
        Segment(title: title, subtitle: subtitle, enabled: enabled, background: true, startMessage: startMessage) { urls in
            var created = 0
            var firstError: Error?
            for url in urls {
                do { created += try convert(url).count }
                catch { firstError = firstError ?? error }
            }
            if created == 0, let firstError { throw firstError }
            let noun = created == 1 ? "archivo convertido" : "archivos convertidos"
            var message = "\(created) \(noun) a \(title)"
            if let firstError { message += "\n(\(firstError.localizedDescription))" }
            return message
        }
    }

    private static func actions() -> [Segment] {
        var list = [
            Segment(title: "Copiar ruta", symbol: "doc.on.clipboard") { urls in
                FileActions.copyPaths(urls)
                return urls.count == 1 ? "Ruta copiada" : "\(urls.count) rutas copiadas"
            },
            Segment(title: "Terminal", symbol: "terminal") { urls in
                try FileActions.openTerminal(at: urls)
                return nil
            },
            Segment(title: "Mostrar", symbol: "folder") { urls in
                FileActions.reveal(urls)
                return nil
            },
            Segment(title: "Duplicar", symbol: "plus.square.on.square", background: true) { urls in
                let copies = try FileActions.duplicate(urls)
                return copies.count == 1 ? "Duplicado" : "\(copies.count) duplicados"
            },
            Segment(title: "ZIP", symbol: "archivebox", background: true) { urls in
                let zip = try FileActions.zip(urls)
                return "Creado \(zip.lastPathComponent)"
            },
            Segment(title: "Mover a…", symbol: "arrow.right.doc.on.clipboard") { urls in
                guard let folder = FileActions.pickFolder(prompt: "Mover aquí") else { return nil }
                try FileActions.move(urls, to: folder)
                return "Movido a \(folder.lastPathComponent)"
            },
        ]

        for path in Settings.shared.favoriteFolders.prefix(Settings.maxFolders) {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let exists = FileManager.default.fileExists(atPath: path)
            list.append(Segment(
                title: folder.lastPathComponent,
                symbol: "folder.badge.plus",
                subtitle: exists ? "copiar" : "no existe",
                enabled: exists,
                background: true
            ) { urls in
                try FileActions.copy(urls, to: folder)
                return "Copiado a \(folder.lastPathComponent)"
            })
        }
        return list
    }
}

/// Ejecuta un gajo después de soltar los archivos y muestra el resultado.
enum Executor {
    static func run(_ segment: Segment, on urls: [URL]) {
        if let start = segment.startMessage { Toast.show(start, ok: true, silent: true) }
        let work = {
            do {
                let message = try segment.perform(urls)
                DispatchQueue.main.async { if let message { Toast.show(message, ok: true) } }
            } catch {
                DispatchQueue.main.async { Toast.show(error.localizedDescription, ok: false) }
            }
        }
        if segment.background {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        } else {
            // Se espera a que termine el arrastre antes de abrir diálogos u otras apps.
            DispatchQueue.main.async(execute: work)
        }
    }
}
