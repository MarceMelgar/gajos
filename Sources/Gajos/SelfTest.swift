import AppKit
import AVFoundation
import CoreMedia
import ServiceManagement
import SwiftUI

/// Pruebas desde la línea de comandos, sin abrir la interfaz.
///   Gajos --selftest <carpeta>              convierte cada archivo con todos los gajos de su tipo
///   Gajos --snapshot <carpeta> <archivo>…   guarda una imagen de la rueda para cada archivo
enum SelfTest {
    static func handle(_ args: [String]) -> Bool {
        // Gajos --open <fondo|tachar|editar|anotar> <imagen>: abre esa ventana sola, como desde la rueda.
        if args.count >= 4, args[1] == "--open" {
            openEditor(args[2], URL(fileURLWithPath: args[3]))
            return true
        }
        // Gajos --login-item on|off: lo mismo que el interruptor "Abrir al iniciar sesión" de Configuración.
        if args.count >= 3, args[1] == "--login-item" {
            do {
                if args[2] == "on" { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                print("Abrir al iniciar sesión: \(SMAppService.mainApp.status == .enabled ? "activado" : "desactivado")")
            } catch {
                print("FAIL \(error.localizedDescription)")
            }
            return true
        }
        guard args.count >= 3 else { return false }
        let folder = URL(fileURLWithPath: args[2], isDirectory: true)
        switch args[1] {
        case "--selftest": run(in: folder)
        case "--snapshot": snapshot(to: folder, files: args.dropFirst(3).map { URL(fileURLWithPath: $0) })
        default: return false
        }
        return true
    }

    private static func run(in folder: URL) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        let mode = ProcessInfo.processInfo.environment["GAJOS_WHEEL"]
        if mode == "videobg" {
            // Fondo para videos: 16:9 con degradado y, por separado, 1:1 con color liso.
            for file in files where MediaKind.of(file) == .video {
                do {
                    let copy = MediaTools.needsPreviewCopy(file) ? try VideoBackground.playableCopy(file) : nil
                    let frame = try VideoBackground.previewFrame(copy ?? file)
                    let w = frame.longSide
                    for (ratio, colors) in [(16.0 / 9, BackgroundPalette.gradients[6]), (1.0, [BackgroundPalette.solids[0]])] {
                        let o = BackgroundOptions(colors: colors, padding: w * 0.08, corners: w * 0.03, shadow: w * 0.02, ratio: ratio)
                        let start = Date()
                        let out = try VideoBackground.export(copy ?? file, options: o, outputLike: file)
                        print("OK   \(file.lastPathComponent) → \(out.lastPathComponent) en \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
                    }
                } catch {
                    print("FAIL \(file.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return
        }
        if mode == "compress" {
            // Por calidad (30 %) y por tamaño final (40 % del original) para cada archivo.
            for file in files {
                let target = Int64(Double(fileSize(file)) * 0.4)
                for (name, t) in [("calidad 30 %", CompressTarget.quality(0.3)), ("tamaño \(formatSize(target))", .size(target))] {
                    let start = Date()
                    do {
                        let msg = try Compressor.compress(file, target: t).replacingOccurrences(of: "\n", with: " ")
                        print("OK   \(file.lastPathComponent) [\(name)] \(msg) (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
                    } catch { print("FAIL \(file.lastPathComponent) [\(name)]: \(error.localizedDescription)") }
                }
            }
            return
        }
        if mode == "gif" {
            // GIF del tramo 2 s → 5 s.
            for file in files where MediaKind.of(file) == .video {
                let range = CMTimeRange(start: CMTime(seconds: 2, preferredTimescale: 600), end: CMTime(seconds: 5, preferredTimescale: 600))
                do { print("OK   GIF \(file.lastPathComponent) → \(try VideoConverter.gif(file, range: range).lastPathComponent)") }
                catch { print("FAIL GIF \(file.lastPathComponent): \(error.localizedDescription)") }
            }
            return
        }
        if mode == "editors" {
            for file in files where MediaKind.of(file) == .image { testEditors(file, output: folder) }
            return
        }
        if mode == "trim" {
            // Recorta del segundo 0,5 al 1,5 de cada audio o video.
            for file in files where [.audio, .video].contains(MediaKind.of(file)) {
                if MediaTools.needsPreviewCopy(file) {
                    do {
                        let copy = try MediaTools.makePreviewCopy(file, isAudio: MediaKind.of(file) == .audio)
                        print("OK   copia para ver \(file.lastPathComponent) → \(copy.lastPathComponent), reproducible: \(AVURLAsset(url: copy).isPlayable)")
                    } catch { print("FAIL copia para ver \(file.lastPathComponent): \(error.localizedDescription)") }
                }
                let range = CMTimeRange(start: CMTime(seconds: 0.5, preferredTimescale: 600),
                                        end: CMTime(seconds: 1.5, preferredTimescale: 600))
                do { print("OK   recortar \(file.lastPathComponent) → \(try MediaTools.trim(file, range: range).lastPathComponent)") }
                catch { print("FAIL recortar \(file.lastPathComponent): \(error.localizedDescription)") }
            }
            return
        }
        let kind: WheelKind = mode == "tools" ? .tools : .conversion
        for file in files {
            // GAJOS_ONLY=MP3 prueba solo los gajos con ese título.
            let only = ProcessInfo.processInfo.environment["GAJOS_ONLY"]
            let segments = Wheels.segments(for: kind, files: [file])
                .filter { $0.background && (only == nil || $0.title == only) }
            if segments.isEmpty { print("--   \(file.lastPathComponent): sin conversiones") }
            for segment in segments {
                guard segment.enabled else {
                    print("--   \(file.lastPathComponent) → \(segment.title): desactivado (\(segment.subtitle ?? ""))")
                    continue
                }
                do {
                    print("OK   \(file.lastPathComponent) → \(segment.title): \(try segment.perform([file]) ?? "")")
                } catch {
                    print("FAIL \(file.lastPathComponent) → \(segment.title): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Aplica cada herramienta de edición y guarda el resultado y una captura de su ventana.
    private static func testEditors(_ file: URL, output folder: URL) {
        guard let image = try? EditableImage.load(file) else { print("FAIL cargar \(file.lastPathComponent)"); return }
        let w = image.size.width, h = image.size.height
        func report(_ name: String, _ result: CGImage?) {
            guard let result else { print("FAIL \(name)"); return }
            do {
                let out = try ImageTools.save(result, like: file, suffix: " \(name)")
                print("OK   \(name): \(result.width)×\(result.height) → \(out.lastPathComponent)")
            } catch { print("FAIL \(name): \(error.localizedDescription)") }
        }

        let bg = BackgroundOptions(colors: BackgroundPalette.gradients[0], padding: w * 0.08, corners: w * 0.03,
                                   shadow: w * 0.02, ratio: 16.0 / 9)
        let start = Date()
        _ = BackgroundRenderer.render(image.preview, bg, scale: image.previewScale)
        print("     vista previa de Fondo: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        report("fondo", BackgroundRenderer.render(image.full, bg))
        // Fondo con imagen propia (la misma imagen girada, para que se note), sin y con desenfoque.
        var turned = EditSettings(); turned.quarterTurns = 2; turned.saturation = 1.6
        if let picture = EditRenderer.render(image.full, turned) {
            for blur in [0.0, w * 0.02] {
                var withPicture = bg
                withPicture.picture = picture
                withPicture.pictureBlur = blur
                report(blur == 0 ? "fondo-imagen" : "fondo-imagen-desenfocada", BackgroundRenderer.render(image.full, withPicture))
            }
        }
        print("     Fondo a tamaño completo: \(Int(Date().timeIntervalSince(start) * 1000)) ms en total")
        let box = CGRect(x: w * 0.1, y: h * 0.1, width: w * 0.35, height: h * 0.25)
        for style in RedactStyle.allCases {
            report("tachado-\(style.rawValue.lowercased())", RedactRenderer.render(image.full, boxes: [box], style: style))
        }
        var edit = EditSettings()
        edit.quarterTurns = 1
        edit.saturation = 0
        report("editado-girado-bn", EditRenderer.render(image.full, edit))
        let red = NSColor.systemRed.usingColorSpace(.sRGB)!.cgColor
        let lw = max(image.longSide / 200, 3)
        let notes = [
            Annotation(kind: .arrow, points: [CGPoint(x: w * 0.1, y: h * 0.9), CGPoint(x: w * 0.4, y: h * 0.55)], color: red, width: lw),
            Annotation(kind: .rectangle, points: [CGPoint(x: w * 0.5, y: h * 0.1), CGPoint(x: w * 0.9, y: h * 0.4)], color: red, width: lw),
            Annotation(kind: .ellipse, points: [CGPoint(x: w * 0.55, y: h * 0.55), CGPoint(x: w * 0.9, y: h * 0.9)], color: red, width: lw),
            Annotation(kind: .pen, points: (0..<20).map { CGPoint(x: w * (0.1 + Double($0) * 0.02), y: h * (0.45 + 0.05 * sin(Double($0)))) }, color: red, width: lw),
            Annotation(kind: .text, points: [CGPoint(x: w * 0.1, y: h * 0.05)], color: red, width: lw, text: "¡Mirá acá!"),
        ]
        report("anotado", AnnotationRenderer.render(image.full, notes))

        // Capturas de las ventanas (con algunas zonas y anotaciones de ejemplo, sin interacción).
        let windows: [(String, AnyView)] = [
            ("ventana-fondo", AnyView(BackgroundToolView(image: image, close: {}))),
            ("ventana-tachar", AnyView(RedactToolView(image: image, close: {}))),
            ("ventana-editar", AnyView(EditToolView(image: image, close: {}))),
            ("ventana-anotar", AnyView(AnnotateToolView(image: image, close: {}))),
        ]
        for (name, view) in windows {
            let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let out = folder.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("     \(out.lastPathComponent)")
        }
    }

    private static func openEditor(_ tool: String, _ file: URL) {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let titles = ["fondo": "Fondo", "tachar": "Tachar", "editar": "Editar", "anotar": "Anotar"]
        guard let title = titles[tool],
              let segment = Wheels.segments(for: .tools, files: [file]).first(where: { $0.title == title }) else {
            print("FAIL no existe el gajo \(tool)")
            return
        }
        DispatchQueue.main.async {
            print("abriendo \(title)…")
            Executor.run(segment, on: [file])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let visible = NSApp.windows.filter(\.isVisible)
                print("ventanas visibles: \(visible.map(\.title))")
                // Captura de la ventana para comprobar que muestra la vista previa.
                if let view = visible.first?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let out = file.deletingLastPathComponent().appendingPathComponent("ventana-abierta.png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: out)
                    print("captura: \(out.path)")
                }
            }
        }
        app.run()
    }

    private static func snapshot(to folder: URL, files: [URL]) {
        let controller = WheelController()
        let samples = files.isEmpty ? [URL(fileURLWithPath: "/System/Library/Desktop Pictures")] : files
        for (i, file) in samples.enumerated() {
            for (kind, name) in [(WheelKind.conversion, "conversion"), (.tools, "herramientas"), (.actions, "acciones")] {
                if kind == .actions, i > 0 { continue }
                guard let rep = controller.snapshot(kind, files: [file]),
                      let png = rep.representation(using: .png, properties: [:]) else { continue }
                let out = folder.appendingPathComponent("rueda-\(name)-\(file.pathExtension).png")
                try? png.write(to: out)
                print(out.path)
            }
        }
    }
}
