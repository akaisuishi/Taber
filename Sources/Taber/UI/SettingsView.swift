import AppKit
import CoreGraphics
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, behavior, shortcuts, permissions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: "Aparência"
        case .behavior: "Comportamento"
        case .shortcuts: "Atalhos e busca"
        case .permissions: "Permissões e sobre"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: "slider.horizontal.3"
        case .behavior: "switch.2"
        case .shortcuts: "command"
        case .permissions: "lock.shield"
        }
    }
    var detail: String {
        switch self {
        case .appearance: "Seu espaço de trabalho, do seu jeito."
        case .behavior: "Pequenos ajustes para o seu dia a dia."
        case .shortcuts: "Entre uma ideia e outra, só um atalho."
        case .permissions: "Tudo acontece aqui, no seu Mac."
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: GlobalShortcutMonitor
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var launchError: String?
    @State private var permissionRevision = 0
    @State private var demoSelection = 1
    let onRequestAccessibility: () -> Void
    let onRequestScreenRecording: () -> Void
    let onPreviewStyle: (SwitcherStyle) -> Void
    private var palette: TaberThemePalette { settings.appTheme.palette }
    private var section: SettingsSection { SettingsSection(rawValue: settings.settingsSection) ?? .appearance }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(palette.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.system(size: 24, weight: .semibold))
                        Text(section.detail).foregroundStyle(palette.secondary)
                    }
                    .accessibilityIdentifier("settings.heading")
                    switch section {
                    case .appearance: appearance
                    case .behavior: behavior
                    case .shortcuts: shortcuts
                    case .permissions: permissions
                    }
                    Spacer(minLength: 0)
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(TaberSurfaceBackground(color: palette.background, material: .windowBackground, tintOpacity: settings.appTheme.transparencyTintOpacity))
        .foregroundStyle(palette.primary)
        .font(.system(size: 13))
        .tint(palette.accent)
        .preferredColorScheme(settings.appTheme.colorScheme)
        .environment(\.colorScheme, settings.appTheme.colorScheme)
        .environment(\.taberThemePalette, palette)
        .environment(\.taberTransparencyEnabled, settings.transparencyEnabled)
        .frame(minWidth: 780, minHeight: 580)
        .onAppear { launchAtLogin = LaunchAtLoginService.isEnabled }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRevision += 1
            monitor.refreshPermissions()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                Text("Taber").font(.system(size: 20, weight: .semibold))
            }.padding(.horizontal, 12)
            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { item in
                    Button { settings.settingsSection = item.rawValue } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 12, weight: section == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(section == item ? palette.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(section == item ? palette.primary : palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.section.\(item.rawValue)")
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            Spacer()
            Label(settings.shortcutEnabled ? "Pronto para alternar" : "Alternância pausada", systemImage: settings.shortcutEnabled ? "circle.fill" : "pause.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.secondary)
                .padding(.horizontal, 12)
            Text("Seu Mac, janela por janela.").font(.system(size: 10)).foregroundStyle(palette.tertiary).padding(.horizontal, 12)
        }
        .padding(.horizontal, 12).padding(.vertical, 28)
        .frame(width: 180)
        .background(TaberSurfaceBackground(color: palette.panel, material: .sidebar))
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("Visual do alternador", detail: "Quatro maneiras de encontrar a próxima janela.")
                HStack(spacing: 8) {
                    ForEach(SwitcherStyle.allCases) { style in
                        Button { settings.switcherStyle = style } label: {
                            VStack(spacing: 10) {
                                StyleMiniature(style: style).frame(height: 46)
                                HStack(spacing: 4) {
                                    Text(style.shortTitle)
                                    if settings.switcherStyle == style { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                                }.font(.system(size: 11, weight: .medium))
                            }
                            .frame(maxWidth: .infinity).padding(10)
                            .background(TaberChoiceSurface(selected: settings.switcherStyle == style))
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("appearance.style.\(style.rawValue)")
                            .accessibilityAddTraits(settings.switcherStyle == style ? .isSelected : [])
                    }
                }
            }
            VStack(spacing: 12) {
                HStack {
                    Label("Prévia interativa", systemImage: "play.rectangle").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("Janelas de exemplo").font(.system(size: 10)).foregroundStyle(palette.tertiary)
                }
                DemoSwitcherPreview(style: settings.switcherStyle, selection: $demoSelection)
                    .frame(height: 152)
                HStack {
                    Text("\(demoSelection + 1) de 3").monospacedDigit()
                    Spacer()
                    Button { demoSelection = (demoSelection + 2) % 3 } label: { Image(systemName: "arrow.left") }
                        .accessibilityLabel("Janela anterior na prévia")
                    Button { demoSelection = (demoSelection + 1) % 3 } label: { Image(systemName: "arrow.right") }
                        .accessibilityLabel("Próxima janela na prévia")
                    Button("Experimentar na tela") { onPreviewStyle(settings.switcherStyle) }
                        .accessibilityIdentifier("appearance.preview")
                }.font(.system(size: 11)).foregroundStyle(palette.secondary)
            }.padding(16).background(palette.panel, in: RoundedRectangle(cornerRadius: TaberDesign.radius))
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Tema", detail: "A mesma identidade, outra luz.")
                    Picker("Tema", selection: $settings.appTheme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("appearance.theme")
                }
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Tamanho", detail: "Encontre seu ritmo de leitura.")
                    Picker("Tamanho", selection: $settings.switcherSize) {
                        ForEach(SwitcherSize.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("appearance.size")
                }
            }
            row("Transparência", "Usa o material do macOS no alternador, painel rápido e Configurações. A opção Reduzir Transparência sempre prevalece.") {
                Toggle("Transparência", isOn: $settings.transparencyEnabled)
                    .labelsHidden()
                    .accessibilityIdentifier("appearance.transparency")
            }
        }
    }

    private var behavior: some View {
        VStack(spacing: 0) {
            row("Alternar com Command + Tab", "Ativa o alternador de janelas do Taber.") { Toggle("Alternar com Command + Tab", isOn: $settings.shortcutEnabled).labelsHidden() }
            Divider()
            row("Abrir ao iniciar sessão", "Sempre pronto quando você ligar o Mac.") {
                Toggle("Abrir ao iniciar sessão", isOn: $launchAtLogin).labelsHidden()
                    .onChange(of: launchAtLogin) { _, enabled in
                        do { try LaunchAtLoginService.setEnabled(enabled); launchError = nil }
                        catch { launchAtLogin = LaunchAtLoginService.isEnabled; launchError = error.localizedDescription }
                    }
            }
            Divider()
            row("Incluir janelas auxiliares", "Painéis visíveis também entram na alternância.") { Toggle("Incluir janelas auxiliares", isOn: $settings.includeUtilityWindows).labelsHidden() }
            if let launchError { Text(launchError).foregroundStyle(.red).padding(.vertical, 12) }
        }.padding(.horizontal, 16).background(palette.panel, in: RoundedRectangle(cornerRadius: TaberDesign.radius))
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 0) {
                row("Próxima janela", "Segure Command para continuar alternando.") { Text("⌘ Tab").modifier(KeycapStyle()) }
                Divider()
                row("Janela anterior", "Volte na sequência de janelas.") { Text("⇧ ⌘ Tab").modifier(KeycapStyle()) }
                Divider()
                row("Navegar", "Miniaturas e Ícones: horizontal. Lista e Fluxo: vertical.") { Text("← →  ↑ ↓").modifier(KeycapStyle()) }
                Divider()
                row("Cancelar", "Mantenha a janela em que você estava.") { Text("Esc").modifier(KeycapStyle()) }
            }.padding(.horizontal, 16).background(palette.panel, in: RoundedRectangle(cornerRadius: TaberDesign.radius))
            VStack(spacing: 0) {
                row("Entrar na busca", "Use este atalho com o alternador aberto.") {
                    Picker("Atalho da busca", selection: $settings.searchShortcut) {
                        ForEach(SearchShortcut.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 150)
                }
                Divider()
                row("Manter busca aberta", "Solte Command, digite e pressione Enter para abrir.") { Toggle("Manter busca aberta", isOn: $settings.keepSearchOpen).labelsHidden() }
            }.padding(.horizontal, 16).background(palette.panel, in: RoundedRectangle(cornerRadius: TaberDesign.radius))
        }
    }

    private var permissions: some View {
        let _ = permissionRevision
        return VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 0) {
                permission("Acessibilidade", "Permite alternar, focar e restaurar janelas.", granted: AccessibilityService.isTrusted, action: onRequestAccessibility)
                Divider()
                permission("Gravação de Tela", "Permite mostrar prévias das suas janelas.", granted: CGPreflightScreenCaptureAccess(), action: onRequestScreenRecording)
            }.padding(.horizontal, 16).background(palette.panel, in: RoundedRectangle(cornerRadius: TaberDesign.radius))
            Button("Verificar permissões novamente") { permissionRevision += 1; monitor.refreshPermissions() }
            VStack(alignment: .leading, spacing: 12) {
                Label("Privado por natureza", systemImage: "lock").font(.headline)
                Text("Os títulos e as prévias ficam no seu Mac. Nenhum conteúdo das suas janelas é enviado a um servidor.").foregroundStyle(palette.secondary)
                Text("Taber \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .font(.caption).foregroundStyle(palette.tertiary)
            }
        }
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary)
        }
    }
    private func row<Content: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            content().toggleStyle(.switch).controlSize(.small)
        }.padding(.vertical, 18)
    }
    private func permission(_ title: String, _ detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        row(title, detail) {
            if granted { Label("Concedida", systemImage: "checkmark.circle").foregroundStyle(palette.secondary).font(.caption) }
            else { Button("Autorizar", action: action) }
        }
    }
}

struct StyleMiniature: View {
    @Environment(\.taberThemePalette) private var palette
    let style: SwitcherStyle
    var body: some View {
        Group {
            switch style {
            case .preview:
                HStack(spacing: 4) { ForEach(0..<3) { i in RoundedRectangle(cornerRadius: 4).fill(i == 1 ? palette.accent.opacity(0.35) : palette.raisedSurface).overlay(alignment: .bottom) { Capsule().fill(palette.secondary.opacity(0.3)).frame(height: 3).padding(5) } } }
            case .list:
                VStack(spacing: 4) { ForEach(0..<3) { i in HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(palette.accent.opacity(0.4)).frame(width: 8); Capsule().fill(palette.secondary.opacity(0.3)) }.padding(3).background(i == 1 ? palette.surface : .clear, in: RoundedRectangle(cornerRadius: 3)) } }
            case .icons:
                HStack(spacing: 8) { ForEach(["safari", "folder", "doc.text"], id: \.self) { Image(systemName: $0).font(.system(size: 18)).foregroundStyle(palette.accent) } }
            case .flow:
                HStack(spacing: 5) { RoundedRectangle(cornerRadius: 4).fill(palette.accent.opacity(0.25)); VStack(spacing: 5) { ForEach(0..<3) { _ in Capsule().fill(palette.secondary.opacity(0.3)) } }.frame(width: 24) }
            }
        }.padding(6)
    }
}

struct DemoSwitcherPreview: View {
    @Environment(\.taberThemePalette) private var palette
    let style: SwitcherStyle
    @Binding var selection: Int
    private let names = ["Projeto — Taber", "Documentos", "Notas de viagem"]
    private let icons = ["safari", "folder", "doc.text"]
    var body: some View {
        Group {
            switch style {
            case .preview:
                HStack(spacing: 8) { ForEach(0..<3) { i in Button { selection = i } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        DemoWindowContent(index: i).frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(names[i]).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }.padding(8).background(TaberChoiceSurface(selected: selection == i))
                }.buttonStyle(.plain) } }
            case .list:
                VStack(spacing: 4) { ForEach(0..<3) { demoRow($0) } }
            case .icons:
                HStack(spacing: 12) { ForEach(0..<3) { i in Button { selection = i } label: {
                    VStack(spacing: 10) { Image(systemName: icons[i]).font(.system(size: 36, weight: .light)).foregroundStyle(palette.accent); Text(names[i]).font(.system(size: 10)).lineLimit(1) }
                        .frame(maxWidth: .infinity).padding(16).background(TaberChoiceSurface(selected: selection == i))
                }.buttonStyle(.plain) } }
            case .flow:
                HStack(spacing: 12) { DemoWindowContent(index: selection).clipShape(RoundedRectangle(cornerRadius: 8)); VStack(spacing: 4) { ForEach(0..<3) { demoRow($0) } }.frame(width: 180) }
            }
        }
    }
    private func demoRow(_ index: Int) -> some View {
        Button { selection = index } label: {
            HStack(spacing: 8) { Image(systemName: icons[index]).foregroundStyle(palette.accent); Text(names[index]).lineLimit(1); Spacer(minLength: 0); Text("\(index + 1)").foregroundStyle(palette.tertiary) }
                .font(.system(size: 11)).padding(10).background(TaberChoiceSurface(selected: selection == index))
        }.buttonStyle(.plain)
    }
}

struct DemoWindowContent: View {
    @Environment(\.taberThemePalette) private var palette
    let index: Int
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) { ForEach(0..<3) { _ in Circle().fill(palette.secondary.opacity(0.35)).frame(width: 4, height: 4) }; Spacer(); Capsule().fill(palette.surface).frame(width: 40, height: 4); Spacer() }.padding(8)
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 7) { ForEach(0..<4) { i in Capsule().fill(i == index ? palette.accent.opacity(0.4) : palette.surface).frame(height: 4) }; Spacer(minLength: 0) }.frame(width: 24)
                VStack(alignment: .leading, spacing: 7) {
                    Text(["Uma nova perspectiva.", "Tudo ao seu alcance.", "Ideias ganham forma."][index % 3]).font(.system(size: 10, weight: .semibold)).lineLimit(2)
                    RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [palette.accent.opacity(0.28), palette.accentSecondary.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(maxHeight: .infinity)
                    Capsule().fill(palette.surface).frame(height: 4)
                }
            }.padding(10)
        }.background(palette.background)
    }
}

extension WindowInfo {
    @MainActor static var demoWindows: [WindowInfo] {
        zip(["Projeto — Taber", "Documentos", "Notas de viagem"], ["safari", "folder", "doc.text"]).enumerated().map { index, item in
            WindowInfo(id: UInt32(index + 1), ownerPID: -1, bundleIdentifier: "com.taber.example.\(index)", applicationName: ["Safari", "Finder", "Notas"][index], title: item.0, bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), isOnScreen: true, isMinimized: false, spaceNumber: index == 2 ? 2 : 1, icon: NSImage(systemSymbolName: item.1, accessibilityDescription: nil))
        }
    }
}
