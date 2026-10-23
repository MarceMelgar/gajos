import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageFormat: CaseIterable {
    case jpg, png, heic, webp, tiff, gif, bmp, pdf

    var title: String {
        switch self {
        case .jpg: return "JPG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .webp: return "WEBP"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .pdf: return "PDF"
        }
    }

    var fileExtension: String { self == .jpg ? "jpg" : title.lowercased() }

    var typeIdentifier: String {
        switch self {
        case .jpg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return UTType.heic.identifier
        case .webp: return UTType.webP.identifier
        case .tiff: return UTType.tiff.identifier
        case .gif: return UTType.gif.identifier
        case .bmp: return UTType.bmp.identifier
        case .pdf: return UTType.pdf.identifier
        }
    }

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg": self = .jpg
        case "png": self = .png
        case "heic", "heif": self = .heic
        case "webp": self = .webp
        case "tif", "tiff": self = .tiff
        case "gif": self = .gif
        case "bmp": self = .bmp
        case "pdf": self = .pdf
        default: return nil
        }
    }

    var isLossy: Bool { [.jpg, .heic, .webp].contains(self) }
    var supportsAlpha: Bool { ![.jpg, .bmp].contains(self) }
}

enum ConvertError: LocalizedError {
    case notAnImage(String)
    case writeFailed(String)
    case webpUnavailable
    case ffmpegUnavailable
    case unreadable(String)
    case protected(String)
    case noAudio
    case incompatible(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnImage(let name): return "\(name) no es una imagen"
        case .writeFailed(let name): return "No se pudo guardar \(name)"
        case .webpUnavailable: return "Para WEBP hace falta instalar cwebp"
        case .ffmpegUnavailable: return "Este formato necesita ffmpeg"
        case .unreadable(let name): return "macOS no puede leer \(name) sin ffmpeg"
        case .protected(let name): return "\(name) está protegido con DRM y no se puede convertir"
        case .noAudio: return "El video no tiene audio"
        case .incompatible(let format): return "Este video no se puede convertir a \(format)"
        case .exportFailed(let message): return "Falló la conversión: \(message)"
        }
    }
}

enum ImageConverter {
    static var cwebpPath: String? {
        ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Convierte una imagen (o cada página de un PDF) y guarda el resultado junto al original.
    @discardableResult
    static func convert(_ url: URL, to format: ImageFormat, quality: Double) throws -> [URL] {
        let images = try loadImages(url)
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent

        if format == .pdf {
            let out = uniqueURL(folder.appendingPathComponent(base).appendingPathExtension("pdf"))
            try writePDF(images, to: out)
            return [out]
        }

        var outputs: [URL] = []
        for (i, image) in images.enumerated() {
            let name = images.count > 1 ? "\(base) \(i + 1)" : base
            let out = uniqueURL(folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension))
            try write(image, to: out, format: format, quality: quality)
            outputs.append(out)
        }
        return outputs
    }

    // MARK: Lectura

    static func loadImages(_ url: URL) throws -> [CGImage] {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
                throw ConvertError.notAnImage(url.lastPathComponent)
            }
            return (0..<doc.pageCount).compactMap { doc.page(at: $0).flatMap(render) }
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ConvertError.notAnImage(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0

        // Una "miniatura" del tamaño completo aplica la rotación EXIF de las fotos.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if width > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return [image]
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConvertError.notAnImage(url.lastPathComponent)
        }
        return [image]
    }

    /// Renderiza una página de PDF a 144 ppp sobre fondo blanco.
    static func render(_ page: PDFPage) -> CGImage? {
        var size = page.bounds(for: .mediaBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        let scale: CGFloat = 2
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        page.draw(with: .mediaBox, to: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Escritura

    static func write(_ image: CGImage, to out: URL, format: ImageFormat, quality: Double) throws {
        if format == .webp {
            try writeWebP(image, to: out, quality: quality)
            return
        }
        let finalImage = (!format.supportsAlpha && hasAlpha(image)) ? flatten(image) ?? image : image
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw ConvertError.writeFailed(out.lastPathComponent)
        }
        var props: [CFString: Any] = [:]
        if format.isLossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, finalImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed(out.lastPathComponent) }
    }

    private static func writeWebP(_ image: CGImage, to out: URL, quality: Double) throws {
        guard let cwebp = cwebpPath else { throw ConvertError.webpUnavailable }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(image, to: temp, format: .png, quality: quality)
        let status = try Shell.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), temp.path, "-o", out.path])
        if status != 0 { throw ConvertError.writeFailed(out.lastPathComponent) }
    }

    private static func writePDF(_ images: [CGImage], to out: URL) throws {
        let doc = PDFDocument()
        for image in images {
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            if let page = PDFPage(image: nsImage) { doc.insert(page, at: doc.pageCount) }
        }
        guard doc.pageCount > 0, doc.write(to: out) else { throw ConvertError.writeFailed(out.lastPathComponent) }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    /// JPG y BMP no tienen transparencia: se pone fondo blanco en vez de negro.
    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
