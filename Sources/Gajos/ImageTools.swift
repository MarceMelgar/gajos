import AppKit
import ImageIO
import PDFKit

/// Herramientas para imágenes. Nunca modifican el original: guardan una copia al lado.
enum ImageTools {
    /// Copia la imagen sin ubicación GPS, datos de la cámara, fechas ni otros datos ocultos.
    /// En JPG, PNG, HEIC y TIFF lo hace sin volver a comprimir, así que no pierde calidad.
    static func stripMetadata(_ url: URL) throws -> String {
        if ImageFormat(fileExtension: url.pathExtension) == .pdf { return try stripPDFMetadata(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else {
            throw ConvertError.notAnImage(url.lastPathComponent)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let removed = describeMetadata(props)
        let out = suffixed(url, " sin metadatos", ext: url.pathExtension)

        // Solo se conserva la orientación, para que la foto no aparezca girada.
        let metadata = CGImageMetadataCreateMutable()
        if let orientation = props[kCGImagePropertyOrientation] as? NSNumber {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyOrientation, orientation)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true,
        ]

        var copied = false
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
            copied = CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil)
        }
        if !copied {
            // Formatos que no admiten la copia directa: se vuelven a guardar solo los píxeles.
            try? FileManager.default.removeItem(at: out)
            guard let image = try ImageConverter.loadImages(url).first else {
                throw ConvertError.notAnImage(url.lastPathComponent)
            }
            let format = ImageFormat(fileExtension: url.pathExtension) ?? .png
            try ImageConverter.write(image, to: out, format: format == .pdf ? .png : format, quality: 0.95)
        }

        return removed.isEmpty
            ? "\(out.lastPathComponent): no tenía datos personales"
            : "\(out.lastPathComponent): se quitó \(removed.joined(separator: ", "))"
    }

    /// Quita autor, título, asunto, palabras clave, programa y fechas del PDF.
    private static func stripPDFMetadata(_ url: URL) throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ConvertError.notAnImage(url.lastPathComponent) }
        if doc.isLocked { throw ConvertError.protected(url.lastPathComponent) }
        let names: [PDFDocumentAttribute: String] = [
            .authorAttribute: "autor", .titleAttribute: "título", .subjectAttribute: "asunto",
            .keywordsAttribute: "palabras clave", .creatorAttribute: "programa", .producerAttribute: "programa",
            .creationDateAttribute: "fechas", .modificationDateAttribute: "fechas",
        ]
        let attributes = doc.documentAttributes ?? [:]
        var removed: [String] = []
        // macOS siempre graba de nuevo la fecha actual y "Quartz" como programa al guardar un PDF.
        for (key, name) in names where attributes[key] != nil && !removed.contains(name) { removed.append(name) }

        doc.documentAttributes = [:]
        let out = suffixed(url, " sin metadatos", ext: "pdf")
        guard doc.write(to: out) else { throw ConvertError.writeFailed(out.lastPathComponent) }
        return removed.isEmpty
            ? "\(out.lastPathComponent): no tenía datos personales"
            : "\(out.lastPathComponent): se quitó \(removed.joined(separator: ", "))"
    }

    /// Guarda una imagen en el mismo formato que el original, con un sufijo en el nombre.
    @discardableResult
    static func save(_ image: CGImage, like source: URL, suffix: String, quality: Double? = nil) throws -> URL {
        var format = ImageFormat(fileExtension: source.pathExtension) ?? .png
        if format == .pdf || (format == .webp && ImageConverter.cwebpPath == nil) { format = .png }
        let out = suffixed(source, suffix, ext: format.fileExtension)
        try ImageConverter.write(image, to: out, format: format, quality: quality ?? Settings.shared.quality)
        return out
    }

    private static func describeMetadata(_ props: [CFString: Any]) -> [String] {
        var found: [String] = []
        if props[kCGImagePropertyGPSDictionary] != nil { found.append("ubicación GPS") }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if tiff[kCGImagePropertyTIFFMake] != nil || tiff[kCGImagePropertyTIFFModel] != nil { found.append("cámara") }
        if exif[kCGImagePropertyExifDateTimeOriginal] != nil || tiff[kCGImagePropertyTIFFDateTime] != nil { found.append("fecha") }
        if tiff[kCGImagePropertyTIFFSoftware] != nil { found.append("programa") }
        if exif.count > 3, !found.contains("cámara") { found.append("datos EXIF") }
        return found
    }

}

/// "foto.jpg" + " recortado" → "foto recortado.jpg", sin pisar archivos existentes.
func suffixed(_ url: URL, _ suffix: String, ext: String) -> URL {
    var out = url.deletingLastPathComponent()
        .appendingPathComponent(url.deletingPathExtension().lastPathComponent + suffix)
    if !ext.isEmpty { out.appendPathExtension(ext) }
    return uniqueURL(out)
}

func fileSize(_ url: URL) -> Int64 {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
}

func formatSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
