import AppKit
import PDFKit
import Vision

/// Opciones de la rueda para un PDF, en el orden de los gajos (desde arriba, en sentido horario).
enum PDFFormat: CaseIterable {
    case docx, jpg, png, txt

    var title: String {
        switch self {
        case .docx: return "DOCX"
        case .jpg: return "JPG"
        case .png: return "PNG"
        case .txt: return "TXT"
        }
    }

    var subtitle: String? {
        switch self {
        case .docx: return "Word"
        case .jpg, .png: return "por página"
        case .txt: return "solo texto"
        }
    }
}

enum PDFConverter {
    /// Devuelve el mensaje para mostrar. Los archivos se guardan junto al PDF.
    static func convert(_ url: URL, to format: PDFFormat) throws -> String {
        switch format {
        case .jpg, .png:
            let outs = try ImageConverter.convert(url, to: format == .jpg ? .jpg : .png, quality: Settings.shared.quality)
            return outs.count == 1 ? "Guardado \(outs[0].lastPathComponent)" : "\(outs.count) páginas guardadas como \(format.title)"
        case .txt:
            let pages = try readPages(url)
            let out = suffixed(url, "", ext: "txt")
            let text = pages.map(\.text).joined(separator: "\n\n")
            try text.write(to: out, atomically: true, encoding: .utf8)
            return message(out, pages)
        case .docx:
            let pages = try readPages(url)
            let out = suffixed(url, "", ext: "docx")
            try writeDOCX(pages, to: out)
            return message(out, pages)
        }
    }

    private struct Page {
        let text: String
        /// Texto con fuentes y estilos, cuando el PDF lo trae (no en páginas escaneadas).
        let styled: NSAttributedString?
        let recognized: Bool
    }

    private static func readPages(_ url: URL) throws -> [Page] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw ConvertError.notAnImage(url.lastPathComponent)
        }
        if doc.isLocked { throw ConvertError.protected(url.lastPathComponent) }

        var pages: [Page] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                pages.append(Page(text: text, styled: page.attributedString, recognized: false))
            } else {
                // Página sin texto (escaneada o foto): se reconoce el texto de la imagen.
                pages.append(Page(text: recognizeText(page), styled: nil, recognized: true))
            }
        }
        if pages.allSatisfy({ $0.text.isEmpty }) {
            throw ConvertError.exportFailed("el PDF no tiene texto que se pueda leer")
        }
        return pages
    }

    /// Reconocimiento de texto de macOS (el mismo que usa Fotos), en español e inglés.
    private static func recognizeText(_ page: PDFPage) -> String {
        guard let image = ImageConverter.render(page) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["es-ES", "en-US"]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    private static func writeDOCX(_ pages: [Page], to out: URL) throws {
        let body = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        for (i, page) in pages.enumerated() {
            if i > 0 {
                // Salto de página entre páginas del PDF.
                body.append(NSAttributedString(string: "\n\u{0C}", attributes: plain))
            }
            body.append(page.styled ?? NSAttributedString(string: page.text, attributes: plain))
        }
        replaceSystemFonts(in: body)
        let data = try body.data(from: NSRange(location: 0, length: body.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: out)
    }

    /// La fuente interna de macOS (".SFNS…") no existe en Word y se vería en Times New Roman.
    private static func replaceSystemFonts(in text: NSMutableAttributedString) {
        let range = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else {
                // Sin fuente, Word usa Times New Roman.
                if let fallback = NSFont(name: "HelveticaNeue", size: 12) {
                    text.addAttribute(.font, value: fallback, range: subrange)
                }
                return
            }
            guard font.fontName.hasPrefix(".") else { return }
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            let name = bold ? "HelveticaNeue-Bold" : "HelveticaNeue"
            if let replacement = NSFont(name: name, size: font.pointSize) {
                text.addAttribute(.font, value: replacement, range: subrange)
            }
        }
    }

    private static func message(_ out: URL, _ pages: [Page]) -> String {
        let recognized = pages.filter(\.recognized).count
        guard recognized > 0 else { return "Guardado \(out.lastPathComponent)" }
        let which = recognized == pages.count ? "el PDF es escaneado" : "\(recognized) páginas escaneadas"
        return "Guardado \(out.lastPathComponent)\n(\(which): el texto se reconoció de la imagen, revisalo)"
    }
}
