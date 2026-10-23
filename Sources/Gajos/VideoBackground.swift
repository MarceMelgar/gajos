import AVFoundation
import CoreImage

/// "Fondo" para videos: el mismo fondo, margen, esquinas, sombra y proporción que en imágenes,
/// aplicado a cada cuadro. El audio se mantiene.
enum VideoBackground {
    /// Lado más largo permitido del resultado (los códecs de Apple llegan a 4K).
    static let maxSide: CGFloat = 3840

    /// Un cuadro del video (cerca del primer segundo) para la vista previa.
    static func previewFrame(_ url: URL) throws -> EditableImage {
        let asset = AVURLAsset(url: url)
        guard asset.isReadable, !asset.tracks(withMediaType: .video).isEmpty else {
            throw ConvertError.unreadable(url.lastPathComponent)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let seconds = min(1, asset.duration.seconds / 2)
        let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
        return EditableImage(frame: frame, url: url)
    }

    @discardableResult
    static func export(_ url: URL, options o: BackgroundOptions) throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw ConvertError.unreadable(url.lastPathComponent) }

        // Tamaño del video ya girado (los videos del celular vienen con rotación).
        let natural = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        let videoSize = CGSize(width: abs(natural.width), height: abs(natural.height))

        // Si con el margen queda más grande que 4K, se achica todo en la misma proporción.
        var l = BackgroundRenderer.layout(imageSize: videoSize, o, evenSize: true)
        var scale: CGFloat = 1
        let longest = max(l.canvas.width, l.canvas.height)
        if longest > maxSide {
            scale = maxSide / longest
            l = BackgroundRenderer.layout(imageSize: CGSize(width: videoSize.width * scale, height: videoSize.height * scale),
                                          o, scale: scale, evenSize: true)
        }
        guard let backdropImage = BackgroundRenderer.backdrop(l, o), let maskImage = BackgroundRenderer.mask(l) else {
            throw ConvertError.writeFailed(url.lastPathComponent)
        }
        let backdrop = CIImage(cgImage: backdropImage)
        let mask = CIImage(cgImage: maskImage)
        let canvas = CGRect(origin: .zero, size: l.canvas)
        let frame = l.frame

        let composition = AVMutableVideoComposition(asset: asset) { request in
            // Cada cuadro se escala, se ubica en su lugar y se recorta con las esquinas redondeadas.
            let source = request.sourceImage
            let placed = source
                .transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: frame.width / source.extent.width,
                                                   y: frame.height / source.extent.height))
                .transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
            let output = placed.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: backdrop,
                kCIInputMaskImageKey: mask,
            ]).cropped(to: canvas)
            request.finish(with: output, context: nil)
        }
        composition.renderSize = l.canvas

        let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let out = suffixed(url, " con fondo", ext: fileType == .mov ? "mov" : "mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ConvertError.incompatible("video con fondo")
        }
        session.outputURL = out
        session.outputFileType = fileType
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = true

        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.exportFailed(session.error?.localizedDescription ?? out.lastPathComponent)
        }
        return out
    }
}
