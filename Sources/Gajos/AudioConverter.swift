import Foundation

enum AudioFormat: CaseIterable {
    case mp3, wav, aiff, m4a, alac, flac, opus, ogg

    var title: String {
        switch self {
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .m4a: return "M4A"
        case .alac: return "ALAC"
        case .flac: return "FLAC"
        case .opus: return "OPUS"
        case .ogg: return "OGG"
        }
    }

    var subtitle: String? {
        switch self {
        case .m4a: return "AAC"
        case .alac: return "sin pérdida"
        default: return nil
        }
    }

    var fileExtension: String {
        switch self {
        case .alac: return "m4a"
        default: return title.lowercased()
        }
    }

    /// Argumentos para afconvert, que viene con macOS. nil si hace falta ffmpeg.
    var afconvertArgs: [String]? {
        switch self {
        case .wav: return ["-f", "WAVE", "-d", "LEI16"]
        case .aiff: return ["-f", "AIFF", "-d", "BEI16"]
        // Calidad variable alta: un bitrate fijo falla con audios mono o de baja frecuencia.
        case .m4a: return ["-f", "m4af", "-d", "aac", "-s", "3", "-u", "vbrq", "100"]
        case .alac: return ["-f", "m4af", "-d", "alac"]
        case .flac: return ["-f", "flac", "-d", "flac"]
        case .mp3, .opus, .ogg: return nil
        }
    }

    var ffmpegArgs: [String] {
        switch self {
        case .mp3: return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .wav: return ["-vn", "-c:a", "pcm_s16le"]
        case .aiff: return ["-vn", "-c:a", "pcm_s16be"]
        case .m4a: return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .alac: return ["-vn", "-c:a", "alac"]
        case .flac: return ["-vn", "-c:a", "flac"]
        case .opus: return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case .ogg: return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        }
    }

    /// Segundo intento si ffmpeg no trae el codificador habitual (el ffmpeg de Homebrew no incluye libvorbis).
    var ffmpegFallbackArgs: [String]? {
        self == .ogg ? ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-q:a", "5"] : nil
    }

    var isAvailable: Bool { afconvertArgs != nil || FFmpeg.path != nil }
}

enum AudioConverter {
    @discardableResult
    static func convert(_ url: URL, to format: AudioFormat) throws -> [URL] {
        let out = uniqueURL(url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(format.fileExtension))

        if let args = format.afconvertArgs {
            // La calidad variable falla al recodificar un audio que ya es AAC; ahí va la opción por defecto.
            let attempts = format == .m4a ? [args, ["-f", "m4af", "-d", "aac"]] : [args]
            for attempt in attempts {
                if (try? Shell.run("/usr/bin/afconvert", attempt + [url.path, out.path])) == 0 { return [out] }
                try? FileManager.default.removeItem(at: out)
            }
        }

        guard FFmpeg.path != nil else {
            if url.pathExtension.lowercased() == "m4p" { throw ConvertError.protected(url.lastPathComponent) }
            throw format.afconvertArgs == nil
                ? ConvertError.ffmpegUnavailable
                : ConvertError.unreadable(url.lastPathComponent)
        }
        do {
            do {
                try FFmpeg.convert(url, to: out, args: format.ffmpegArgs)
            } catch {
                guard let fallback = format.ffmpegFallbackArgs else { throw error }
                try FFmpeg.convert(url, to: out, args: fallback)
            }
        } catch {
            if url.pathExtension.lowercased() == "m4p" { throw ConvertError.protected(url.lastPathComponent) }
            throw error
        }
        return [out]
    }
}
