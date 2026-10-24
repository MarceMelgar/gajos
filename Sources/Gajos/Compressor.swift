import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Cuánto comprimir: por calidad (0,1 … 1) o apuntando a un tamaño final en bytes.
enum CompressTarget {
    case quality(Double)
    case size(Int64)
}

/// Compresión a medida para imágenes, audio, video y PDF.
/// Siempre guarda una copia con " comprimido" en el nombre; el original no se toca.
enum Compressor {
    static func compress(_ url: URL, target: CompressTarget) throws -> String {
        let before = fileSize(url)
        let kind: MediaKind? = url.pathExtension.lowercased() == "pdf" ? nil : MediaKind.of(url)
        let out: URL
        var note: String?
        switch kind {
        case nil where url.pathExtension.lowercased() == "pdf":
            (out, note) = try compressPDF(url, target)
        case .image:
            (out, note) = try compressImage(url, target)
        case .audio:
            out = try compressAudio(url, target)
        case .video:
            out = try compressVideo(url, target)
        default:
            throw ConvertError.notAnImage(url.lastPathComponent)
        }

        let after = fileSize(out)
        if after >= before {
            try? FileManager.default.removeItem(at: out)
            return "\(url.lastPathComponent) ya está optimizado: con esa opción no se achica más"
        }
        var message = "\(out.lastPathComponent): \(formatSize(before)) → \(formatSize(after))"
        if case .size(let bytes) = target, after > Int64(Double(bytes) * 1.05) {
            message += "\n(no se pudo llegar a \(formatSize(bytes)); es lo más chico posible)"
        }
        if let note { message += "\n(\(note))" }
        return message
    }

    // MARK: Imágenes

    private static func compressImage(_ url: URL, _ target: CompressTarget) throws -> (URL, String?) {
        guard let image = try ImageConverter.loadImages(url).first else { throw ConvertError.notAnImage(url.lastPathComponent) }
        var format = ImageFormat(fileExtension: url.pathExtension) ?? .jpg
        if format == .webp, ImageConverter.cwebpPath == nil { format = .jpg }
        let out = suffixed(url, " comprimido", ext: format.fileExtension)
        // PNG, BMP, GIF y TIFF no tienen "calidad": se achican las medidas.
        let lossy = format.isLossy
        var note: String? = lossy ? nil : "en \(format.title) se achican las medidas de la imagen"

        let data: Data
        switch target {
        case .quality(let q):
            data = lossy
                ? try encode(image, format, quality: 0.05 + q * 0.9)
                : try encode(scaled(image, by: sqrt(q)), format, quality: 1)
        case .size(let bytes):
            var best: Data?
            if lossy {
                // Se busca la calidad más alta que entra en el tamaño; si ni la mínima entra, se achican las medidas.
                var current = image
                for _ in 0..<5 {
                    if let found = try search(bytes, { try encode(current, format, quality: 0.05 + $0 * 0.9) }) {
                        best = found
                        break
                    }
                    let smallest = try encode(current, format, quality: 0.05)
                    best = smallest
                    current = scaled(current, by: max(sqrt(Double(bytes) / Double(smallest.count)) * 0.95, 0.3))
                    note = "se achicaron las medidas para llegar al tamaño"
                }
            } else {
                best = try search(bytes, { try encode(scaled(image, by: max($0, 0.05)), format, quality: 1) })
                if best == nil { best = try encode(scaled(image, by: 0.05), format, quality: 1) }
            }
            if let best { data = best } else { data = try encode(image, format, quality: 0.05) }
        }
        try data.write(to: out)
        return (out, note)
    }

    /// Búsqueda binaria del valor más alto (0…1) cuyo resultado entra en `bytes`. nil si ni el mínimo entra.
    private static func search(_ bytes: Int64, _ make: (Double) throws -> Data) throws -> Data? {
        var low = 0.0, high = 1.0
        var best: Data?
        let top = try make(high)
        if top.count <= bytes { return top }
        for _ in 0..<7 {
            let mid = (low + high) / 2
            let data = try make(mid)
            if data.count <= bytes { best = data; low = mid } else { high = mid }
        }
        if best == nil {
            let bottom = try make(0)
            if bottom.count <= bytes { best = bottom }
        }
        return best
    }

    private static func encode(_ image: CGImage, _ format: ImageFormat, quality: Double) throws -> Data {
        if format == .webp, let cwebp = ImageConverter.cwebpPath {
            let folder = FileManager.default.temporaryDirectory
            let png = folder.appendingPathComponent(UUID().uuidString + ".png")
            let webp = folder.appendingPathComponent(UUID().uuidString + ".webp")
            defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: webp) }
            try ImageConverter.write(image, to: png, format: .png, quality: 1)
            guard try Shell.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), png.path, "-o", webp.path]) == 0 else {
                throw ConvertError.writeFailed("WEBP")
            }
            return try Data(contentsOf: webp)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil) else {
            throw ConvertError.writeFailed(format.title)
        }
        let flat = format.supportsAlpha ? image : (flatten(image) ?? image)
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed(format.title) }
        return data as Data
    }

    private static func scaled(_ image: CGImage, by factor: Double) -> CGImage {
        guard factor < 0.999 else { return image }
        return Draw.downscale(image, maxSide: CGFloat(max(image.width, image.height)) * CGFloat(factor))
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    // MARK: Audio

    /// kbps según la calidad (32 a 320) o según el tamaño buscado y la duración.
    private static func audioBitrate(_ url: URL, _ target: CompressTarget) throws -> Int {
        switch target {
        case .quality(let q):
            return Int((32 + q * 288).rounded())
        case .size(let bytes):
            let seconds = duration(url)
            guard seconds > 0 else { throw ConvertError.unreadable(url.lastPathComponent) }
            let kbps = Int(Double(bytes) * 8 / seconds / 1000 * 0.95)
            guard kbps >= 16 else { throw ConvertError.exportFailed("el tamaño es demasiado chico para un audio de esa duración") }
            return min(kbps, 320)
        }
    }

    private static func compressAudio(_ url: URL, _ target: CompressTarget) throws -> URL {
        let kbps = try audioBitrate(url, target)
        let ext = url.pathExtension.lowercased()
        // Con ffmpeg se mantiene el formato en MP3 y OPUS; si no, se guarda en M4A (AAC).
        if FFmpeg.path != nil, ext == "mp3" || ext == "opus" {
            let out = suffixed(url, " comprimido", ext: ext)
            let codec = ext == "mp3" ? "libmp3lame" : "libopus"
            try FFmpeg.convert(url, to: out, args: ["-vn", "-c:a", codec, "-b:a", "\(kbps)k"])
            return out
        }
        let out = suffixed(url, " comprimido", ext: "m4a")
        if FFmpeg.path != nil {
            try FFmpeg.convert(url, to: out, args: ["-vn", "-c:a", "aac", "-b:a", "\(kbps)k"])
            return out
        }
        // Sin ffmpeg: afconvert acepta solo ciertos bitrates según el audio; se prueba con el pedido y luego más bajos.
        for rate in [kbps, kbps * 3 / 4, kbps / 2, 64, 32] where rate >= 16 {
            if (try? Shell.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", String(rate * 1000), url.path, out.path])) == 0 {
                return out
            }
            try? FileManager.default.removeItem(at: out)
        }
        throw ConvertError.unreadable(url.lastPathComponent)
    }

    static func duration(_ url: URL) -> Double {
        let seconds = AVURLAsset(url: url).duration.seconds
        if seconds.isFinite, seconds > 0 { return seconds }
        // Formatos que macOS no abre: se le pregunta a ffprobe (viene con ffmpeg).
        guard let ffmpeg = FFmpeg.path else { return 0 }
        let ffprobe = (ffmpeg as NSString).deletingLastPathComponent + "/ffprobe"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return 0 }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: Video

    /// true si se puede elegir tamaño final para videos (hace falta ffmpeg).
    static var canTargetVideoSize: Bool { FFmpeg.path != nil }

    private static func compressVideo(_ url: URL, _ target: CompressTarget) throws -> URL {
        let out = suffixed(url, " comprimido", ext: "mp4")
        switch target {
        case .quality(let q):
            if FFmpeg.path != nil {
                // CRF de HEVC: 36 (más liviano) a 18 (casi sin pérdida).
                let crf = Int((36 - q * 18).rounded())
                try FFmpeg.convert(url, to: out, args: [
                    "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx265", "-crf", "\(crf)", "-preset", "fast",
                    "-tag:v", "hvc1", "-c:a", "aac", "-b:a", q > 0.6 ? "192k" : "128k", "-movflags", "+faststart",
                ])
                return out
            }
            // Sin ffmpeg: los ajustes que trae macOS, de mejor a peor.
            let asset = AVURLAsset(url: url)
            guard asset.isReadable else { throw ConvertError.unreadable(url.lastPathComponent) }
            let options = q >= 0.75 ? [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
                : q >= 0.5 ? [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080]
                : q >= 0.3 ? [AVAssetExportPreset1280x720]
                : [AVAssetExportPreset960x540, AVAssetExportPreset640x480]
            let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
            let preset = options.first { compatible.contains($0) } ?? AVAssetExportPresetMediumQuality
            try AVExport.run(asset, preset: preset, fileType: .mp4, to: out)
            return out

        case .size(let bytes):
            guard let ffmpeg = FFmpeg.path else {
                throw ConvertError.exportFailed("para elegir el tamaño final de un video hace falta instalar los formatos extra (ffmpeg)")
            }
            let seconds = duration(url)
            guard seconds > 0 else { throw ConvertError.unreadable(url.lastPathComponent) }
            let totalKbps = Double(bytes) * 8 / seconds / 1000 * 0.96
            let audioKbps: Double = totalKbps > 1000 ? 128 : totalKbps > 300 ? 64 : 32
            let videoKbps = Int(totalKbps - audioKbps)
            guard videoKbps >= 50 else {
                throw ConvertError.exportFailed("el tamaño es demasiado chico para un video de esa duración")
            }
            // Con poco bitrate se ve mejor más chico.
            let height = videoKbps < 500 ? 480 : videoKbps < 1500 ? 720 : 1080
            let scale = "scale=-2:'min(\(height),ih)'"

            // Dos pasadas: la primera mide el video y la segunda reparte los bits para clavar el tamaño.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gajos-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let log = folder.appendingPathComponent("pasada").path
            let common = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", url.path,
                          "-map", "0:v:0", "-vf", scale, "-c:v", "libx264", "-preset", "medium",
                          "-b:v", "\(videoKbps)k", "-pix_fmt", "yuv420p", "-passlogfile", log]
            guard try Shell.run(ffmpeg, common + ["-pass", "1", "-an", "-f", "null", "/dev/null"]) == 0 else {
                throw ConvertError.writeFailed(out.lastPathComponent)
            }
            let second = common + ["-pass", "2", "-map", "0:a:0?", "-c:a", "aac", "-b:a", "\(Int(audioKbps))k",
                                   "-movflags", "+faststart", out.path]
            guard try Shell.run(ffmpeg, second) == 0 else {
                try? FileManager.default.removeItem(at: out)
                throw ConvertError.writeFailed(out.lastPathComponent)
            }
            return out
        }
    }

    // MARK: PDF

    /// Calidad alta: se optimizan las imágenes del PDF y el texto se mantiene.
    /// Más compresión: cada página se guarda como imagen (el texto deja de poder seleccionarse).
    private static func compressPDF(_ url: URL, _ target: CompressTarget) throws -> (URL, String?) {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { throw ConvertError.notAnImage(url.lastPathComponent) }
        if doc.isLocked { throw ConvertError.protected(url.lastPathComponent) }
        let out = suffixed(url, " comprimido", ext: "pdf")
        let rasterNote = "las páginas se guardaron como imágenes: el texto ya no se puede seleccionar"
        // Las páginas se dibujan una sola vez; cada intento solo cambia la resolución y la calidad JPEG.
        var pages: [PDFRasterPage]?
        func rasterized(quality: Double) throws -> Data {
            if pages == nil { pages = renderPages(doc) }
            return try Compressor.rasterized(pages ?? [], quality: quality)
        }

        func optimized() throws -> Data {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at: temp) }
            var options: [PDFDocumentWriteOption: Any] = [:]
            if #available(macOS 14, *) { options = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true] }
            guard doc.write(to: temp, withOptions: options) else { throw ConvertError.writeFailed(out.lastPathComponent) }
            return try Data(contentsOf: temp)
        }

        switch target {
        case .quality(let q):
            if q >= 0.9 {
                try optimized().write(to: out)
                return (out, nil)
            }
            try rasterized(quality: q).write(to: out)
            return (out, rasterNote)
        case .size(let bytes):
            let keep = try optimized()
            if keep.count <= bytes {
                try keep.write(to: out)
                return (out, nil)
            }
            var data = try search(bytes, { try rasterized(quality: max($0, 0.05) * 0.85) })
            if data == nil { data = try rasterized(quality: 0.05) }
            try data?.write(to: out)
            return (out, rasterNote)
        }
    }

    private struct PDFRasterPage {
        let image: CGImage
        let box: CGRect
    }

    /// Cada página dibujada a 144 ppp, con su tamaño en puntos.
    private static func renderPages(_ doc: PDFDocument) -> [PDFRasterPage] {
        (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i), let image = ImageConverter.render(page) else { return nil }
            var box = page.bounds(for: .mediaBox)
            if page.rotation % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
            box.origin = .zero
            return PDFRasterPage(image: image, box: box)
        }
    }

    /// Cada página como JPEG: la resolución y la calidad bajan juntas.
    private static func rasterized(_ pages: [PDFRasterPage], quality q: Double) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ConvertError.writeFailed("PDF") }
        let dpi = 60 + q * 160
        for page in pages {
            let rendered = page.image
            // Las páginas están a 144 ppp; se achican a la resolución elegida y se comprimen en JPEG.
            let image = Draw.downscale(rendered, maxSide: CGFloat(max(rendered.width, rendered.height)) * CGFloat(dpi / 144))
            let jpeg = try encode(image, .jpg, quality: 0.1 + q * 0.8)
            guard let provider = CGDataProvider(data: jpeg as CFData),
                  let embedded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                         intent: .defaultIntent) else { continue }
            var box = page.box
            pdf.beginPage(mediaBox: &box)
            pdf.draw(embedded, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
        return data as Data
    }
}
