import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

/// "Fondo": pone la imagen sobre un fondo de color o degradado, con margen, esquinas redondeadas y sombra.
struct BackgroundOptions {
    var colors: [CGColor]
    var padding: CGFloat
    var corners: CGFloat
    var shadow: CGFloat
    /// Ancho / alto del resultado; nil = se ajusta a la imagen más el margen.
    var ratio: CGFloat?
    /// Imagen propia de fondo (reemplaza los colores); cubre todo el lienzo sin deformarse.
    var picture: CGImage? = nil
    /// Desenfoque de la imagen de fondo, en píxeles del resultado.
    var pictureBlur: CGFloat = 0
}

enum BackgroundRenderer {
    /// Medidas del resultado: el lienzo y dónde va la imagen (origen abajo a la izquierda).
    struct Layout {
        let canvas: CGSize
        let frame: CGRect
        let radius: CGFloat
        let shadow: CGFloat
        /// Escala aplicada a las medidas (vista previa o video achicado).
        var scale: CGFloat = 1

        var path: CGPath { CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil) }
    }

    /// `scale` achica todas las medidas, para la vista previa o para videos demasiado grandes.
    /// `evenSize` redondea el lienzo a medidas pares, que es lo que piden los códecs de video.
    static func layout(imageSize: CGSize, _ o: BackgroundOptions, scale s: CGFloat = 1, evenSize: Bool = false) -> Layout {
        let iw = imageSize.width, ih = imageSize.height
        let pad = o.padding * s
        var w = iw + 2 * pad, h = ih + 2 * pad
        if let r = o.ratio {
            if w / h < r { w = h * r } else { h = w / r }
        }
        w = w.rounded(); h = h.rounded()
        if evenSize {
            w += w.truncatingRemainder(dividingBy: 2)
            h += h.truncatingRemainder(dividingBy: 2)
        }
        let frame = CGRect(x: ((w - iw) / 2).rounded(), y: ((h - ih) / 2).rounded(), width: iw, height: ih)
        return Layout(canvas: CGSize(width: w, height: h), frame: frame,
                      radius: min(o.corners * s, min(iw, ih) / 2), shadow: o.shadow * s, scale: s)
    }

    static func render(_ image: CGImage, _ o: BackgroundOptions, scale s: CGFloat = 1) -> CGImage? {
        let l = layout(imageSize: CGSize(width: image.width, height: image.height), o, scale: s)
        guard let ctx = backdropContext(l, o) else { return nil }
        ctx.saveGState()
        ctx.addPath(l.path)
        ctx.clip()
        ctx.draw(image, in: l.frame)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Solo el fondo y la sombra, sin la imagen: para videos, donde cada cuadro se pone encima.
    static func backdrop(_ l: Layout, _ o: BackgroundOptions) -> CGImage? {
        backdropContext(l, o)?.makeImage()
    }

    /// Forma de la imagen con esquinas redondeadas (blanco sobre transparente), para recortar cada cuadro.
    static func mask(_ l: Layout) -> CGImage? {
        guard let ctx = Draw.context(width: Int(l.canvas.width), height: Int(l.canvas.height)) else { return nil }
        ctx.addPath(l.path)
        ctx.setFillColor(.white)
        ctx.fillPath()
        return ctx.makeImage()
    }

    private static let ciContext = CIContext()

    /// Dibuja la imagen de fondo cubriendo todo el lienzo (recortando lo que sobra), con desenfoque opcional.
    private static func drawPicture(_ picture: CGImage, blur: CGFloat, in ctx: CGContext, canvas: CGRect) {
        let pw = CGFloat(picture.width), ph = CGFloat(picture.height)
        let scale = max(canvas.width / pw, canvas.height / ph)
        let rect = CGRect(x: (canvas.width - pw * scale) / 2, y: (canvas.height - ph * scale) / 2,
                          width: pw * scale, height: ph * scale)
        var image = picture
        if blur > 0.5 {
            // Se desenfoca a la escala en que se va a dibujar, para que el efecto sea igual en vista previa y resultado.
            let source = CIImage(cgImage: picture).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let blurred = source.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
                .cropped(to: source.extent)
            if let cg = ciContext.createCGImage(blurred, from: source.extent) { image = cg }
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
    }

    private static func backdropContext(_ l: Layout, _ o: BackgroundOptions) -> CGContext? {
        guard let ctx = Draw.context(width: Int(l.canvas.width), height: Int(l.canvas.height)) else { return nil }
        let canvas = CGRect(origin: .zero, size: l.canvas)
        if let picture = o.picture {
            drawPicture(picture, blur: o.pictureBlur * l.scale, in: ctx, canvas: canvas)
        } else if o.colors.count > 1,
           let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: o.colors as CFArray, locations: nil) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.maxY), end: CGPoint(x: canvas.maxX, y: 0), options: [])
        } else {
            ctx.setFillColor(o.colors.first ?? .white)
            ctx.fill(canvas)
        }
        if l.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -l.shadow * 0.35), blur: l.shadow,
                          color: CGColor(gray: 0, alpha: 0.45))
            ctx.addPath(l.path)
            ctx.setFillColor(.white)
            ctx.fillPath()
            ctx.restoreGState()
        }
        return ctx
    }
}

enum BackgroundPalette {
    private static func c(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let gradients: [[CGColor]] = [
        [c(0xFF8A3D), c(0xF5576C)],             // naranja a rosa
        [c(0xFFE0B2), c(0xFFFFFF)],             // crema
        [c(0xA1C4FD), c(0xC2E9FB)],             // cielo
        [c(0xFBC2EB), c(0xA6C1EE)],             // rosa a lavanda
        [c(0xF6D365), c(0xFDA085)],             // durazno
        [c(0x43E97B), c(0x38F9D7)],             // menta
        [c(0x667EEA), c(0x764BA2)],             // violeta
        [c(0xFF9A9E), c(0xFECFEF), c(0xF6D365)], // atardecer
        [c(0x232526), c(0x414345)],             // grafito
    ]

    static let solids: [CGColor] = [
        c(0xFFFFFF), c(0xF7D774), c(0xF5A04A), c(0x5DBB63), c(0x2E9E8F),
        c(0x5BC6E8), c(0x3B6FD8), c(0x4B3FA8), c(0x8E44AD), c(0x1C1C1E),
    ]
}

struct BackgroundToolView: View {
    let image: EditableImage
    let close: () -> Void
    /// Si es un video, `image` es un cuadro para la vista previa y al guardar se procesa el video entero.
    var isVideo = false
    /// Copia en MP4 para procesar cuando el original es MKV, WEBM… (se borra al terminar).
    var videoCopy: URL?

    private enum Fill: Hashable { case gradient(Int), solid(Int), custom, picture }
    private static let ratios: [(String, CGFloat?)] = [("Auto", nil), ("1:1", 1), ("16:9", 16.0 / 9), ("4:5", 4.0 / 5)]

    @State private var fill: Fill = .gradient(0)
    @State private var custom = Color.orange
    @State private var padding: Double
    @State private var corners: Double
    @State private var shadow: Double
    @State private var ratio = 0
    @State private var preview: CGImage?
    @State private var saving = false
    @State private var picture: CGImage?
    @State private var pictureName = ""
    @State private var pictureBlur = 0.0

    init(image: EditableImage, isVideo: Bool = false, videoCopy: URL? = nil, close: @escaping () -> Void) {
        self.image = image
        self.isVideo = isVideo
        self.videoCopy = videoCopy
        self.close = close
        _padding = State(initialValue: Self.defaults(image).padding)
        _corners = State(initialValue: Self.defaults(image).corners)
        _shadow = State(initialValue: Self.defaults(image).shadow)
    }

    /// Valores iniciales proporcionales al tamaño de la imagen.
    private static func defaults(_ image: EditableImage) -> (padding: Double, corners: Double, shadow: Double) {
        let long = Double(image.longSide)
        return ((long * 0.08).rounded(), (long * 0.025).rounded(), (long * 0.02).rounded())
    }

    private var options: BackgroundOptions {
        let colors: [CGColor]
        switch fill {
        case .gradient(let i): colors = BackgroundPalette.gradients[i]
        case .solid(let i): colors = [BackgroundPalette.solids[i]]
        case .custom, .picture: colors = [NSColor(custom).usingColorSpace(.sRGB)?.cgColor ?? .white]
        }
        return BackgroundOptions(colors: colors, padding: padding, corners: corners, shadow: shadow,
                                 ratio: Self.ratios[ratio].1,
                                 picture: fill == .picture ? picture : nil, pictureBlur: pictureBlur)
    }

    /// Cambia cada vez que cambia algo que afecta la vista previa.
    private var previewKey: String {
        "\(fill)|\(NSColor(custom).usingColorSpace(.sRGB)?.hexString ?? "")|\(Int(padding))|\(Int(corners))|\(Int(shadow))|\(ratio)|\(pictureName)|\(Int(pictureBlur))"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let preview {
                    ImageCanvas(image: preview, coordinateSize: CGSize(width: preview.width, height: preview.height))
                } else {
                    Color(white: 0.12)
                    ProgressView()
                }
            }
            controls
        }
        .frame(minWidth: 640, minHeight: 620)
        // La vista previa se dibuja en segundo plano para que la ventana nunca se trabe.
        .task(id: previewKey) {
            let source = image.preview, options = options, scale = image.previewScale
            let rendered = await Task.detached(priority: .userInitiated) {
                BackgroundRenderer.render(source, options, scale: scale)
            }.value
            if !Task.isCancelled { preview = rendered }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("Fondo").frame(width: 90, alignment: .leading).padding(.top, 4)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach(BackgroundPalette.gradients.indices, id: \.self) { i in
                            swatch(LinearGradient(colors: BackgroundPalette.gradients[i].map { Color(cgColor: $0) },
                                                  startPoint: .topLeading, endPoint: .bottomTrailing), .gradient(i))
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(BackgroundPalette.solids.indices, id: \.self) { i in
                            swatch(Color(cgColor: BackgroundPalette.solids[i]), .solid(i))
                        }
                        // Solo cambia el fondo cuando la persona elige un color (no cuando el selector se actualiza solo).
                        ColorPicker("", selection: Binding(get: { custom }, set: { custom = $0; fill = .custom }),
                                    supportsOpacity: false)
                            .labelsHidden()
                            .help("Otro color")
                        if let picture {
                            swatch(ImagePaint(image: Image(nsImage: picture.nsImage), scale: 22 / CGFloat(picture.height)), .picture)
                                .help(pictureName)
                        }
                        Button(action: choosePicture) {
                            Label(picture == nil ? "Imagen…" : "Otra imagen…", systemImage: "photo.on.rectangle")
                        }
                        .help("Usar una imagen de tu Mac como fondo")
                    }
                }
            }
            if fill == .picture {
                SliderRow(title: "Desenfoque", value: $pictureBlur, range: 0...Double(image.longSide * 0.05))
            }
            SliderRow(title: "Margen", value: $padding, range: 0...Double(image.longSide * 0.4))
            SliderRow(title: "Esquinas", value: $corners, range: 0...Double(image.longSide * 0.2))
            SliderRow(title: "Sombra", value: $shadow, range: 0...Double(image.longSide * 0.08))
            HStack(spacing: 12) {
                Text("Proporción").frame(width: 90, alignment: .leading)
                Picker("", selection: $ratio) {
                    ForEach(Self.ratios.indices, id: \.self) { Text(Self.ratios[$0].0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
            }
            if isVideo {
                Text("La vista previa muestra un cuadro del video. Al guardar se procesa el video entero, con su audio; puede tardar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Restablecer", action: reset)
                Spacer()
                Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
                Button(saving ? "Guardando…" : (isVideo ? "Guardar video con fondo" : "Guardar con fondo"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(18)
        .background(.bar)
    }

    private func swatch<S: ShapeStyle>(_ style: S, _ value: Fill) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(style)
            .frame(width: 30, height: 22)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(fill == value ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: fill == value ? 2.5 : 1))
            .onTapGesture { fill = value }
    }

    /// A tamaño completo puede tardar más de un segundo: se dibuja en segundo plano.
    private func save() {
        if isVideo {
            // El video puede tardar: se cierra la ventana y se avisa al terminar.
            let url = image.url, options = options, copy = videoCopy
            close()
            Toast.show("Agregando fondo al video…", ok: true, silent: true)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    defer { if let copy { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) } }
                    let out = try VideoBackground.export(copy ?? url, options: options, outputLike: url)
                    DispatchQueue.main.async { Toast.show("Guardado \(out.lastPathComponent)", ok: true) }
                } catch {
                    DispatchQueue.main.async { Toast.show(error.localizedDescription, ok: false) }
                }
            }
            return
        }
        saving = true
        let full = image.full, options = options
        DispatchQueue.global(qos: .userInitiated).async {
            let result = BackgroundRenderer.render(full, options)
            DispatchQueue.main.async {
                saving = false
                image.save(result, suffix: " con fondo", close: close)
            }
        }
    }

    /// Elegir una imagen de la Mac para usar de fondo.
    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Usar de fondo"
        panel.message = "Elegí una imagen para el fondo"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let loaded = try ImageConverter.loadImages(url).first else { throw ConvertError.notAnImage(url.lastPathComponent) }
            // No hace falta más resolución que la del resultado más grande (4K).
            picture = Draw.downscale(loaded, maxSide: 4000)
            pictureName = url.lastPathComponent
            fill = .picture
        } catch {
            Toast.show(error.localizedDescription, ok: false)
        }
    }

    private func reset() {
        let d = Self.defaults(image)
        fill = .gradient(0)
        pictureBlur = 0
        padding = d.padding
        corners = d.corners
        shadow = d.shadow
        ratio = 0
    }
}

extension NSColor {
    var hexString: String {
        String(format: "%02X%02X%02X", Int(redComponent * 255), Int(greenComponent * 255), Int(blueComponent * 255))
    }
}
