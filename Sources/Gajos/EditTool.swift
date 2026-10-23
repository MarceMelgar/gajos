import AppKit
import CoreImage
import SwiftUI

/// "Editar": brillo, contraste, saturación, exposición, nitidez, rotar y voltear.
struct EditSettings: Equatable {
    var brightness = 0.0   // -0,5 … 0,5
    var contrast = 1.0     // 0,5 … 1,5
    var saturation = 1.0   // 0 … 2
    var exposure = 0.0     // -2 … 2
    var sharpness = 0.0    // 0 … 2
    var quarterTurns = 0   // giros de 90° a la derecha
    var flipH = false
    var flipV = false
}

enum EditRenderer {
    private static let context = CIContext()

    static func render(_ image: CGImage, _ e: EditSettings) -> CGImage? {
        var out = CIImage(cgImage: image)
        if e.brightness != 0 || e.contrast != 1 || e.saturation != 1 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: e.brightness,
                kCIInputContrastKey: e.contrast,
                kCIInputSaturationKey: e.saturation,
            ])
        }
        if e.exposure != 0 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: e.exposure])
        }
        if e.sharpness > 0 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: e.sharpness])
        }
        out = out.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if e.flipH { out = out.oriented(.upMirrored) }
        if e.flipV { out = out.oriented(.downMirrored) }
        for _ in 0..<(e.quarterTurns % 4) { out = out.oriented(.right) }
        // Que el resultado empiece en (0, 0).
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        return context.createCGImage(out, from: out.extent)
    }
}

struct EditToolView: View {
    let image: EditableImage
    let close: () -> Void
    @State private var settings = EditSettings()

    var body: some View {
        VStack(spacing: 0) {
            if let preview = EditRenderer.render(image.preview, settings) {
                ImageCanvas(image: preview, coordinateSize: CGSize(width: preview.width, height: preview.height))
            }
            VStack(alignment: .leading, spacing: 10) {
                SliderRow(title: "Brillo", value: $settings.brightness, range: -0.5...0.5, format: percent(0, 0.5))
                SliderRow(title: "Contraste", value: $settings.contrast, range: 0.5...1.5, format: percent(1, 0.5))
                SliderRow(title: "Saturación", value: $settings.saturation, range: 0...2, format: percent(1, 1))
                SliderRow(title: "Exposición", value: $settings.exposure, range: -2...2, format: { String(format: "%+.1f", $0) })
                SliderRow(title: "Nitidez", value: $settings.sharpness, range: 0...2, format: percent(0, 2))
                HStack {
                    Button { settings.quarterTurns = (settings.quarterTurns + 3) % 4 } label: {
                        Label("Girar a la izquierda", systemImage: "rotate.left")
                    }
                    Button { settings.quarterTurns = (settings.quarterTurns + 1) % 4 } label: {
                        Label("Girar a la derecha", systemImage: "rotate.right")
                    }
                    Button { settings.flipH.toggle() } label: {
                        Label("Voltear", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    Button { settings.flipV.toggle() } label: {
                        Label("Voltear vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                }
                .labelStyle(.iconOnly)
                .help("Girar y voltear")
                HStack {
                    Button("Restablecer") { settings = EditSettings() }
                        .disabled(settings == EditSettings())
                    Spacer()
                    Button("Cancelar", action: close).keyboardShortcut(.cancelAction)
                    Button("Guardar") {
                        image.save(EditRenderer.render(image.full, settings), suffix: " editado", close: close)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings == EditSettings())
                }
            }
            .padding(18)
            .background(.bar)
        }
        .frame(minWidth: 640, minHeight: 640)
    }

    /// Muestra el valor como porcentaje respecto del valor neutro.
    private func percent(_ neutral: Double, _ span: Double) -> (Double) -> String {
        { value in
            let p = Int(((value - neutral) / span * 100).rounded())
            return p == 0 ? "0" : String(format: "%+d", p)
        }
    }
}
