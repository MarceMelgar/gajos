import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            FoldersTab().tabItem { Label("Carpetas", systemImage: "folder") }
            AboutTab().tabItem { Label("Acerca de", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 520)
    }
}

private struct GeneralTab: View {
    @ObservedObject private var settings = Settings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Apariencia") {
                Picker("Estilo", selection: $settings.style) {
                    Text("Vidrio").tag(WheelStyle.glass)
                    Text("Sólido").tag(WheelStyle.solid)
                }
                .pickerStyle(.segmented)
            }

            Section("General") {
                Toggle("Abrir al iniciar sesión", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Sonido y vibración", isOn: $settings.sound)
            }

            Section {
                Picker("Rueda de conversión", selection: $settings.conversionModifier) {
                    ForEach(Modifier.allCases) { Text($0.label).tag($0) }
                }
                Picker("Rueda de herramientas", selection: $settings.toolsModifier) {
                    ForEach(Modifier.allCases) { Text($0.label).tag($0) }
                }
                Picker("Rueda de acciones", selection: $settings.actionsModifier) {
                    ForEach(Modifier.allCases) { Text($0.label).tag($0) }
                }
                if Set([settings.conversionModifier, settings.toolsModifier, settings.actionsModifier]).count < 3 {
                    Text("Hay ruedas con la misma tecla: solo se abrirá una de ellas.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Teclas al arrastrar")
            } footer: {
                Text("Mientras arrastrás archivos, tocá la tecla y soltala. La rueda queda abierta: soltá el archivo sobre un gajo.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Conversión") {
                HStack {
                    Slider(value: $settings.quality, in: 0.3...1) { Text("Calidad JPG/HEIC/WEBP") }
                    Text("\(Int(settings.quality * 100))%").monospacedDigit().frame(width: 40)
                }
                if ImageConverter.cwebpPath == nil || FFmpeg.path == nil {
                    Text("Algunos formatos están desactivados porque macOS no los trae: WEBP necesita cwebp, y MP3, OGG, OPUS, WEBM, MKV y AVI necesitan ffmpeg. Instalá Homebrew y luego `brew install webp ffmpeg`.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Terminal") {
                Picker("App de terminal", selection: $settings.terminalBundleID) {
                    ForEach(TerminalApp.installed) { Text($0.name).tag($0.bundleID) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "No se pudo cambiar: \(error.localizedDescription). Probá moviendo Gajos a Aplicaciones."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct FoldersTab: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                if settings.favoriteFolders.isEmpty {
                    Text("Todavía no agregaste carpetas.").foregroundStyle(.secondary)
                }
                ForEach(settings.favoriteFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                            Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.favoriteFolders.removeAll { $0 == path }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Agregar carpeta…", action: addFolder)
                    .disabled(settings.favoriteFolders.count >= Settings.maxFolders)
            } header: {
                Text("Carpetas favoritas")
            } footer: {
                Text("Cada carpeta aparece como un gajo en la rueda de acciones y copia ahí los archivos. Máximo \(Settings.maxFolders).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addFolder() {
        guard let url = FileActions.pickFolder(prompt: "Agregar"),
              !settings.favoriteFolders.contains(url.path) else { return }
        settings.favoriteFolders.append(url.path)
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Gajos").font(.title.bold())
            Text("Versión \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").foregroundStyle(.secondary)
            Text("Convertí y editá imágenes, audio, video y PDF arrastrándolos y tocando una tecla. Todo funciona en tu Mac, sin internet.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Divider().frame(maxWidth: 240).padding(.vertical, 4)
            Text("Hecho por **Marce Melgar**")
            Link("github.com/MarceMelgar/gajos", destination: URL(string: "https://github.com/MarceMelgar/gajos")!)
                .font(.callout)
            Text("Inspirado en Tangerine, de Thameem (@th2049)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
