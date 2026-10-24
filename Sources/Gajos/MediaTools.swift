import AVFoundation
import UniformTypeIdentifiers

/// Herramientas para audio y video. Nunca modifican el original: guardan una copia al lado.
enum MediaTools {
    /// Copia el archivo sin título, autor, ubicación ni otros datos, sin volver a comprimir.
    static func stripMetadata(_ url: URL) throws -> String {
        let asset = AVURLAsset(url: url)
        let count = asset.metadata.count
        let out = suffixed(url, " sin metadatos", ext: url.pathExtension)

        if asset.isReadable, let fileType = fileType(of: url),
           let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
           session.supportedFileTypes.contains(fileType) {
            try AVExport.run(asset, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: out, stripMetadata: true)
        } else if let format = AudioFormat.allCases.first(where: { $0.fileExtension == url.pathExtension.lowercased() }),
                  let args = format.afconvertArgs,
                  (try? Shell.run("/usr/bin/afconvert", args + [url.path, out.path])) == 0 {
            // FLAC y otros: se recodifica en el mismo formato (sin pérdida), lo que descarta las etiquetas.
        } else if FFmpeg.path != nil {
            try FFmpeg.convert(url, to: out, args: ["-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"])
        } else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.unreadable(url.lastPathComponent)
        }

        // Quedan datos técnicos del codificador (duración, relleno); solo se cuentan los quitados.
        let removed = count - AVURLAsset(url: out).metadata.count
        switch removed {
        case ...0: return "\(out.lastPathComponent): no tenía datos personales"
        case 1: return "\(out.lastPathComponent): se quitó 1 dato"
        default: return "\(out.lastPathComponent): se quitaron \(removed) datos"
        }
    }

    /// Guarda solo el tramo elegido. Sin recodificar cuando el formato lo permite.
    @discardableResult
    static func trim(_ url: URL, range: CMTimeRange) throws -> URL {
        let asset = AVURLAsset(url: url)
        if !asset.isPlayable { return try trimWithFFmpeg(url, range: range) }
        if let fileType = fileType(of: url),
           let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
           session.supportedFileTypes.contains(fileType) {
            let out = suffixed(url, " recortado", ext: url.pathExtension)
            try AVExport.run(asset, preset: AVAssetExportPresetPassthrough, fileType: fileType, to: out, timeRange: range)
            return out
        }
        let isAudio = asset.tracks(withMediaType: .video).isEmpty
        let out = suffixed(url, " recortado", ext: isAudio ? "m4a" : "mp4")
        try AVExport.run(asset, preset: isAudio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality,
                         fileType: isAudio ? .m4a : .mp4, to: out, timeRange: range)
        return out
    }

    // MARK: Formatos que macOS no abre (MKV, WEBM, AVI, OGG, OPUS…)

    /// true si el reproductor de macOS no puede abrir el archivo y hace falta una copia para verlo.
    static func needsPreviewCopy(_ url: URL) -> Bool {
        !AVURLAsset(url: url).isPlayable
    }

    /// Copia temporal que macOS sí puede reproducir, solo para elegir el tramo en la ventana de recorte.
    /// Primero intenta copiar el video sin recodificar (instantáneo); si no se puede reproducir, lo recodifica chico.
    static func makePreviewCopy(_ url: URL, isAudio: Bool) throws -> URL {
        guard FFmpeg.path != nil else { throw ConvertError.unreadable(url.lastPathComponent) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gajos-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(isAudio ? "vista.m4a" : "vista.mp4")

        let attempts: [[String]] = isAudio
            ? [["-vn", "-c:a", "aac", "-b:a", "128k"]]
            : [["-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy", "-tag:v", "avc1", "-c:a", "aac", "-b:a", "128k"],
               ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=-2:'min(720,ih)'", "-c:v", "libx264", "-preset", "veryfast",
                "-crf", "28", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k"]]
        for args in attempts {
            try? FileManager.default.removeItem(at: out)
            if (try? FFmpeg.convert(url, to: out, args: args)) != nil, AVURLAsset(url: out).isPlayable {
                return out
            }
        }
        try? FileManager.default.removeItem(at: folder)
        throw ConvertError.unreadable(url.lastPathComponent)
    }

    /// Corta el original con ffmpeg, en el mismo formato y sin recodificar (rápido y sin perder calidad).
    /// El inicio se ajusta al cuadro clave más cercano, como hace QuickTime.
    private static func trimWithFFmpeg(_ url: URL, range: CMTimeRange) throws -> URL {
        guard let ffmpeg = FFmpeg.path else { throw ConvertError.ffmpegUnavailable }
        let out = suffixed(url, " recortado", ext: url.pathExtension)
        let start = String(format: "%.3f", max(range.start.seconds, 0))
        let duration = String(format: "%.3f", range.duration.seconds)
        let status = try Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin",
                                            "-ss", start, "-i", url.path, "-t", duration,
                                            "-map", "0", "-c", "copy", "-avoid_negative_ts", "make_zero", out.path])
        if status != 0 {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.writeFailed(out.lastPathComponent)
        }
        return out
    }

    private static func fileType(of url: URL) -> AVFileType? {
        UTType(filenameExtension: url.pathExtension).map { AVFileType(rawValue: $0.identifier) }
    }
}

enum AVExport {
    static func run(_ asset: AVAsset, preset: String, fileType: AVFileType, to out: URL,
                    timeRange: CMTimeRange? = nil, stripMetadata: Bool = false) throws {
        if fileType == .m4a, asset.tracks(withMediaType: .audio).isEmpty {
            throw ConvertError.noAudio
        }
        // La copia directa (passthrough) no figura en la lista de presets compatibles, pero funciona.
        let compatible = preset == AVAssetExportPresetPassthrough
            || AVAssetExportSession.exportPresets(compatibleWith: asset).contains(preset)
        guard compatible,
              let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(fileType) else {
            throw ConvertError.incompatible(out.pathExtension.uppercased())
        }
        session.outputURL = out
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if stripMetadata {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        }

        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        done.wait()

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.exportFailed(session.error?.localizedDescription ?? out.lastPathComponent)
        }
    }
}
