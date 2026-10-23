import AppKit
import CoreImage
import SwiftUI

/// "Tachar": tapa zonas de la imagen (datos personales, caras, números) en negro, pixeladas o desenfocadas.
enum RedactStyle: String, CaseIterable, Identifiable {
    case black = "Negro", pixelate = "Pixelar", blur = "Desenfocar"
    var id: String { rawValue }
}

enum RedactRenderer {
    private static let context = CIContext()

    /// `boxes` está en píxeles de la imagen original (origen arriba a la izquierda).
    static func render(_ image: CGImage, boxes: [CGRect], style: RedactStyle, scale s: CGFloat = 1) -> CGImage? {
        var out = CIImage(cgImage: image)
        let height = CGFloat(image.height)
        for box in boxes {
            // CoreImage tiene el origen abajo a la izquierda.
            let r = CGRect(x: box.minX * s, y: height - box.maxY * s, width: box.width * s, height: box.height * s).integral
            guard r.width >= 1, r.height >= 1 else { continue }
            let patch: CIImage
            switch style {
            case .black:
                patch = CIImage(color: .black).cropped(to: r)
            case .pixelate:
                let block = max(min(r.width, r.height) / 12, 8 * s)
                patch = out.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block,
                                                                kCIInputCenterKey: CIVector(x: r.minX, y: r.minY)])
                    .cropped(to: r)
            case .blur:
                let radius = max(min(r.width, r.height) / 4, 8 * s)
                patch = out.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                    .cropped(to: r)
            }
            out = patch.composited(over: out)
        }
        return context.createCGImage(out, from: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}

struct RedactToolView: View {
    let image: EditableImage
    let close: () -> Void

    @State private var boxes: [CGRect] = []
    @State private var drawing: CGRect?
    @State private var style: RedactStyle = .black

    private var allBoxes: [CGRect] { boxes + (drawing.map { [$0] } ?? []) }

    var body: some View {
        VStack(spacing: 0) {
            if let preview = RedactRenderer.render(image.preview, boxes: allBoxes, style: style, scale: image.previewScale) {
                ImageCanvas(image: preview, coordinateSize: image.size) { start, current, ended in
                    let box = rect(from: start, to: current)
                    if ended {
                        drawing = nil
                        if box.width > 3, box.height > 3 { boxes.append(box) }
                    } else {
                        drawing = box
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Arrastrá sobre la imagen para tapar una zona. Podés marcar varias.")
                    .font(.callout).foregroundStyle(.secondary)
                if style != .black {
                    Text("Para textos o números importantes, usá Negro: pixelado y desenfoque a veces se pueden revertir.")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Picker("Estilo", selection: $style) {
                        ForEach(RedactStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    Button("Deshacer") { _ = boxes.popLast() }
                        .keyboardShortcut("z")
                        .disabled(boxes.isEmpty)
                    Button("Borrar todo") { boxes.removeAll() }
                        .disabled(boxes.isEmpty)
                    Spacer()
                    Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
                    Button("Guardar") {
                        image.save(RedactRenderer.render(image.full, boxes: boxes, style: style), suffix: " tachado", close: close)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(boxes.isEmpty)
                }
            }
            .padding(18)
            .background(.bar)
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}
