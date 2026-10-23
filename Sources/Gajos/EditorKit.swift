import AppKit
import SwiftUI

/// Ventana con contenido SwiftUI para las herramientas de imagen (Fondo, Tachar, Editar, Anotar).
final class EditorWindow: NSObject, NSWindowDelegate {
    private static var open: Set<EditorWindow> = []
    private let window: NSWindow

    private init(title: String, size: NSSize, root: AnyView) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
        window.delegate = self
    }

    /// `build` recibe una función para cerrar la ventana.
    static func present<Content: View>(title: String, size: NSSize = NSSize(width: 920, height: 720),
                                       _ build: (@escaping () -> Void) -> Content) {
        var editor: EditorWindow?
        let content = build { editor?.window.close() }
        let created = EditorWindow(title: title, size: size, root: AnyView(content))
        editor = created
        open.insert(created)
        NSApp.activate(ignoringOtherApps: true)
        created.window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.remove(self)
    }
}

/// Imagen que se está editando: la original a tamaño completo y una copia chica para la vista previa.
struct EditableImage {
    let url: URL
    let full: CGImage
    let preview: CGImage
    /// Píxeles de la vista previa por cada píxel de la original (≤ 1).
    let previewScale: CGFloat

    var size: CGSize { CGSize(width: full.width, height: full.height) }
    var longSide: CGFloat { max(size.width, size.height) }

    static func load(_ url: URL) throws -> EditableImage {
        guard let full = try ImageConverter.loadImages(url).first else {
            throw ConvertError.notAnImage(url.lastPathComponent)
        }
        return EditableImage(frame: full, url: url)
    }

    /// A partir de una imagen ya cargada (por ejemplo, un cuadro de un video).
    init(frame full: CGImage, url: URL) {
        let preview = Draw.downscale(full, maxSide: 1100)
        self.init(url: url, full: full, preview: preview, previewScale: CGFloat(preview.width) / CGFloat(full.width))
    }

    private init(url: URL, full: CGImage, preview: CGImage, previewScale: CGFloat) {
        self.url = url
        self.full = full
        self.preview = preview
        self.previewScale = previewScale
    }

    /// Guarda el resultado al lado del original y cierra la ventana.
    func save(_ image: CGImage?, suffix: String, close: () -> Void) {
        guard let image else {
            Toast.show("No se pudo generar la imagen", ok: false)
            return
        }
        do {
            let out = try ImageTools.save(image, like: url, suffix: suffix)
            close()
            Toast.show("Guardado \(out.lastPathComponent)", ok: true)
        } catch {
            Toast.show(error.localizedDescription, ok: false)
        }
    }
}

enum Draw {
    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func downscale(_ image: CGImage, maxSide: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
        guard let ctx = context(width: width, height: height) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    /// Rectángulo donde entra `size` dentro de `bounds`, centrado y sin deformar.
    static func fit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}

extension CGImage {
    var nsImage: NSImage { NSImage(cgImage: self, size: NSSize(width: width, height: height)) }
}

/// Muestra una imagen ajustada al espacio disponible y traduce el mouse a píxeles de la imagen
/// (origen arriba a la izquierda). El arrastre informa inicio, posición actual y si terminó.
struct ImageCanvas: View {
    let image: CGImage
    /// Tamaño de referencia de las coordenadas que se devuelven (normalmente la imagen original).
    let coordinateSize: CGSize
    var onDrag: ((CGPoint, CGPoint, Bool) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let frame = Draw.fit(CGSize(width: image.width, height: image.height),
                                 in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 20, dy: 20))
            ZStack(alignment: .topLeading) {
                Color(white: 0.12)
                Image(nsImage: image.nsImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .shadow(color: .black.opacity(0.35), radius: 8)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onDrag?(convert(value.startLocation, frame), convert(value.location, frame), false)
                    }
                    .onEnded { value in
                        onDrag?(convert(value.startLocation, frame), convert(value.location, frame), true)
                    }
            )
        }
    }

    private func convert(_ p: CGPoint, _ frame: CGRect) -> CGPoint {
        let sx = coordinateSize.width / max(frame.width, 1), sy = coordinateSize.height / max(frame.height, 1)
        return CGPoint(x: min(max((p.x - frame.minX) * sx, 0), coordinateSize.width),
                       y: min(max((p.y - frame.minY) * sy, 0), coordinateSize.height))
    }
}

/// Fila "Nombre  [slider]  valor" usada en las ventanas de edición.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { "\(Int($0.rounded())) px" }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
    }
}

func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}
