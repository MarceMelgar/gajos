import AppKit
import SwiftUI

/// "Anotar": flechas, rectángulos, círculos, lápiz y texto sobre la imagen.
enum AnnotationKind: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, pen, text
    var id: String { rawValue }

    var label: String {
        switch self {
        case .arrow: return "Flecha"
        case .rectangle: return "Rectángulo"
        case .ellipse: return "Círculo"
        case .pen: return "Lápiz"
        case .text: return "Texto"
        }
    }

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .text: return "textformat"
        }
    }
}

struct Annotation {
    var kind: AnnotationKind
    /// En píxeles de la imagen original, origen arriba a la izquierda.
    var points: [CGPoint]
    var color: CGColor
    /// Grosor del trazo en píxeles de la imagen original.
    var width: CGFloat
    var text = ""
}

enum AnnotationRenderer {
    static func render(_ image: CGImage, _ annotations: [Annotation], scale s: CGFloat = 1) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = Draw.context(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Coordenadas con el origen arriba a la izquierda, como las anotaciones.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: s, y: -s)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for a in annotations { draw(a, in: ctx) }
        return ctx.makeImage()
    }

    private static func draw(_ a: Annotation, in ctx: CGContext) {
        guard let first = a.points.first, let last = a.points.last else { return }
        ctx.setStrokeColor(a.color)
        ctx.setFillColor(a.color)
        ctx.setLineWidth(a.width)
        switch a.kind {
        case .arrow:
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(a.width * 4, 12)
            ctx.move(to: first)
            ctx.addLine(to: CGPoint(x: last.x - cos(angle) * head * 0.6, y: last.y - sin(angle) * head * 0.6))
            ctx.strokePath()
            let spread: CGFloat = .pi / 7
            ctx.move(to: last)
            ctx.addLine(to: CGPoint(x: last.x - cos(angle - spread) * head, y: last.y - sin(angle - spread) * head))
            ctx.addLine(to: CGPoint(x: last.x - cos(angle + spread) * head, y: last.y - sin(angle + spread) * head))
            ctx.closePath()
            ctx.fillPath()
        case .rectangle:
            ctx.stroke(rect(from: first, to: last))
        case .ellipse:
            ctx.strokeEllipse(in: rect(from: first, to: last))
        case .pen:
            ctx.addLines(between: a.points)
            ctx.strokePath()
        case .text:
            guard !a.text.isEmpty else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: a.width * 6, weight: .bold),
                .foregroundColor: NSColor(cgColor: a.color) ?? .red,
            ]
            NSAttributedString(string: a.text, attributes: attrs).draw(at: first)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

struct AnnotateToolView: View {
    let image: EditableImage
    let close: () -> Void

    private static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]

    @State private var annotations: [Annotation] = []
    @State private var current: Annotation?
    @State private var kind: AnnotationKind = .arrow
    @State private var colorIndex = 0
    @State private var thickness = 4.0
    @State private var text = ""

    /// El grosor se expresa en relación con el tamaño de la imagen, para que se vea igual en fotos chicas y grandes.
    private var strokeWidth: CGFloat { CGFloat(thickness) * max(image.longSide / 800, 1) }
    private var color: CGColor { Self.colors[colorIndex].usingColorSpace(.sRGB)?.cgColor ?? .black }

    var body: some View {
        VStack(spacing: 0) {
            let all = annotations + (current.map { [$0] } ?? [])
            if let preview = AnnotationRenderer.render(image.preview, all, scale: image.previewScale) {
                ImageCanvas(image: preview, coordinateSize: image.size, onDrag: drag)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Picker("Herramienta", selection: $kind) {
                        ForEach(AnnotationKind.allCases) { Image(systemName: $0.symbol).help($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    HStack(spacing: 6) {
                        ForEach(Self.colors.indices, id: \.self) { i in
                            Circle()
                                .fill(Color(nsColor: Self.colors[i]))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(colorIndex == i ? Color.accentColor : Color.primary.opacity(0.25),
                                                         lineWidth: colorIndex == i ? 3 : 1))
                                .onTapGesture { colorIndex = i }
                        }
                    }
                    Spacer()
                }
                if kind == .text {
                    HStack {
                        TextField("Escribí el texto y después hacé clic donde va", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                        Spacer()
                    }
                }
                SliderRow(title: kind == .text ? "Tamaño" : "Grosor", value: $thickness, range: 1...16,
                          format: { "\(Int($0.rounded()))" })
                HStack {
                    Button("Deshacer") { _ = annotations.popLast() }
                        .keyboardShortcut("z")
                        .disabled(annotations.isEmpty)
                    Button("Borrar todo") { annotations.removeAll() }
                        .disabled(annotations.isEmpty)
                    Spacer()
                    Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
                    Button("Guardar") {
                        image.save(AnnotationRenderer.render(image.full, annotations), suffix: " anotado", close: close)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(annotations.isEmpty)
                }
            }
            .padding(18)
            .background(.bar)
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private func drag(start: CGPoint, point: CGPoint, ended: Bool) {
        if kind == .text {
            guard ended, !text.isEmpty else { return }
            annotations.append(Annotation(kind: .text, points: [point], color: color, width: strokeWidth, text: text))
            text = ""
            return
        }
        if current == nil {
            current = Annotation(kind: kind, points: [start], color: color, width: strokeWidth)
        }
        if kind == .pen {
            current?.points.append(point)
        } else {
            current?.points = [start, point]
        }
        if ended {
            if let done = current, hypot(point.x - start.x, point.y - start.y) > 3 || kind == .pen {
                annotations.append(done)
            }
            current = nil
        }
    }
}
