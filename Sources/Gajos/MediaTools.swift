import AVFoundation
import UniformTypeIdentifiers

/// Herramientas para audio y video. Nunca modifican el original: guardan una copia al lado.
enum MediaTools {
    static func compress(_ url: URL, kind: MediaKind) throws -> String {
        let before = fileSize(url)
        let out: URL
        if kind == .video {
            let asset = AVURLAsset(url: url)
            guard asset.isReadable else { throw ConvertError.unreadable(url.lastPathComponent) }
            // HEVC a 1080p como máximo: suele dejar el video en una fracción del tamaño.
            let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
            let preset = [AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1920x1080, AVAssetExportPresetMediumQuality]
                .first { compatible.contains($0) } ?? AVAssetExportPresetMediumQuality
            out = suffixed(url, " comprimido", ext: "mp4")
            try AVExport.run(asset, preset: preset, fileType: .mp4, to: out)
        } else {
            out = suffixed(url, " comprimido", ext: "m4a")
            let attempts = [
                ["-f", "m4af", "-d", "aac", "-s", "3", "-u", "vbrq", "64"],
                ["-f", "m4af", "-d", "aac"],
            ]
            var ok = false
            for args in attempts where !ok {
                ok = (try? Shell.run("/usr/bin/afconvert", args + [url.path, out.path])) == 0
                if !ok { try? FileManager.default.removeItem(at: out) }
            }
            if !ok {
                guard FFmpeg.path != nil else { throw ConvertError.unreadable(url.lastPathComponent) }
                try FFmpeg.convert(url, to: out, args: ["-vn", "-c:a", "aac", "-b:a", "128k"])
            }
        }

        let after = fileSize(out)
        if after >= before {
            try? FileManager.default.removeItem(at: out)
            return "\(url.lastPathComponent) ya está optimizado: no se pudo achicar más"
        }
        return "\(out.lastPathComponent): \(formatSize(before)) → \(formatSize(after))"
    }

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
