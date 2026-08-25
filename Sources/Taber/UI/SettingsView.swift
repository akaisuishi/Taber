import AppKit
import CoreGraphics
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var monitor: GlobalShortcutMonitor
    @State private var launchAtLogin = LaunchAtLoginService.isEnabled
    @State private var launchAtLoginError: String?
    @State private var permissionRevision = 0

    private let onRequestAccessibility: () -> Void
    private let onRequestScreenRecording: () -> Void
    private let onPreviewStyle: (SwitcherStyle) -> Void

    private var palette: TaberThemePalette { settings.appTheme.palette }
    private var versionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    init(
        settings: SettingsStore,
        monitor: GlobalShortcutMonitor,
        onRequestAccessibility: @escaping () -> Void,
        onRequestScreenRecording: @escaping () -> Void,
        onPreviewStyle: @escaping (SwitcherStyle) -> Void
    ) {
        self.settings = settings
        self.monitor = monitor
        self.onRequestAccessibility = onRequestAccessibility
        self.onRequestScreenRecording = onRequestScreenRecording
        self.onPreviewStyle = onPreviewStyle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brandHeader
                monitorCard
                runtimeNotice
                themeSection
                appearanceSection
                behaviorSection
                permissionsSection
                footer
            }
            .padding(28)
        }
        .background {
            ZStack {
                palette.background
                LinearGradient(
                    colors: [
                        palette.accent.opacity(settings.appTheme == .dark ? 0.025 : 0.10),
                        palette.accentSecondary.opacity(settings.appTheme == .dark ? 0.015 : 0.065),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(palette.primary)
        .tint(palette.accent)
        .preferredColorScheme(settings.appTheme.colorScheme)
        .environment(\.taberThemePalette, palette)
        .frame(minWidth: 680, minHeight: 680)
        .onAppear { launchAtLogin = LaunchAtLoginService.isEnabled }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionRevision += 1
            monitor.refreshPermissions()
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 17) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .shadow(color: palette.accent.opacity(0.24), radius: 16, y: 7)
            VStack(alignment: .leading, spacing: 5) {
                Text("Taber")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Seu Mac, janela por janela.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Command + Tab como sempre deveria ter sido.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(versionText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private var themeSection: some View {
        section(title: "Tema", subtitle: "Escolha a atmosfera do Taber nas configurações e no alternador.") {
            HStack(spacing: 10) {
                ForEach(AppTheme.allCases) { theme in
                    let themePalette = theme.palette
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            settings.appTheme = theme
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Image(systemName: theme.symbolName)
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                                HStack(spacing: -3) {
                                    Circle().fill(themePalette.accentSecondary).frame(width: 13, height: 13)
                                    Circle().fill(themePalette.accent).frame(width: 13, height: 13)
                                    Circle().fill(themePalette.panel).frame(width: 13, height: 13)
                                }
                            }
                            .foregroundStyle(themePalette.accent)

                            Text(theme.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(themePalette.primary)
                            Text(theme.description)
                                .font(.caption2)
                                .foregroundStyle(themePalette.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(themePalette.panel)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(
                                    settings.appTheme == theme
                                        ? themePalette.accent.opacity(0.85)
                                        : themePalette.border,
                                    lineWidth: settings.appTheme == theme ? 1.5 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var monitorCard: some View {
        HStack(spacing: 14) {
            Image(systemName: monitor.state.symbolName)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(monitor.state == .active ? .green : .orange)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(monitor.state.title)
                    .font(.headline)
                Text(monitor.state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $settings.shortcutEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(17)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(monitor.state == .active ? Color.green.opacity(0.09) : Color.orange.opacity(0.09))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(monitor.state == .active ? Color.green.opacity(0.25) : Color.orange.opacity(0.25))
        }
    }

    @ViewBuilder
    private var runtimeNotice: some View {
        if Bundle.main.bundleURL.path != "/Applications/Taber.app" {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Build temporária do Xcode")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Use a mesma equipe de assinatura da versão instalada. Builds ad hoc não preservam permissões.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "hammer.fill")
                    .foregroundStyle(.yellow)
            }
            .padding(13)
            .background(Color.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var appearanceSection: some View {
        section(title: "Visual do alternador", subtitle: "Escolha como suas janelas aparecem ao segurar Command.") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(SwitcherStyle.allCases) { style in
                    Button {
                        settings.switcherStyle = style
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: symbol(for: style))
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(settings.switcherStyle == style ? palette.accent : palette.secondary)
                            Text(shortTitle(for: style))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(shortDescription(for: style))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 95, alignment: .leading)
                        .padding(13)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(settings.switcherStyle == style ? palette.accent.opacity(0.13) : palette.surface)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(settings.switcherStyle == style ? palette.accent.opacity(0.65) : palette.border)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tamanho da interface")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Ajusta texto, miniaturas, ícones, espaçamento e quantidade visível.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 9) {
                    ForEach(SwitcherSize.allCases) { size in
                        Button {
                            settings.switcherSize = size
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: size.symbolName)
                                    .font(.system(size: 15, weight: .semibold))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(size.title)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(size.description)
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(settings.switcherSize == size ? palette.accent.opacity(0.13) : palette.surface)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(settings.switcherSize == size ? palette.accent.opacity(0.65) : palette.border)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    onPreviewStyle(settings.switcherStyle)
                } label: {
                    Label("Pré-visualizar \(shortTitle(for: settings.switcherStyle))", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var behaviorSection: some View {
        section(title: "Comportamento", subtitle: "Deixe o Taber presente sem precisar pensar nele.") {
            VStack(spacing: 0) {
                settingRow(
                    icon: "power",
                    title: "Abrir ao iniciar sessão",
                    detail: "Mantém o Command + Tab pronto após ligar o Mac."
                ) {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, enabled in
                            do {
                                try LaunchAtLoginService.setEnabled(enabled)
                                launchAtLoginError = nil
                            } catch {
                                launchAtLogin = LaunchAtLoginService.isEnabled
                                launchAtLoginError = error.localizedDescription
                            }
                        }
                }
                Divider().padding(.leading, 45)
                settingRow(
                    icon: "command",
                    title: "Manter busca aberta",
                    detail: "Depois de entrar na busca, soltar Command mantém o Taber aberto para você digitar."
                ) {
                    Toggle("", isOn: $settings.keepSearchOpen)
                        .labelsHidden()
                }
                Divider().padding(.leading, 45)
                settingRow(
                    icon: "magnifyingglass",
                    title: "Atalho da busca",
                    detail: "Com o alternador aberto e o Command pressionado, use o atalho e digite o nome da janela."
                ) {
                    Picker("Atalho da busca", selection: $settings.searchShortcut) {
                        ForEach(SearchShortcut.allCases) { shortcut in
                            Text("\(shortcut.hint) — \(shortcut.title)")
                                .tag(shortcut)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                Divider().padding(.leading, 45)
                settingRow(
                    icon: "rectangle.stack.badge.plus",
                    title: "Incluir janelas auxiliares",
                    detail: "Inclui somente painéis auxiliares visíveis; agentes em segundo plano continuam ocultos."
                ) {
                    Toggle("", isOn: $settings.includeUtilityWindows)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 14)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 13))

            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var permissionsSection: some View {
        let _ = permissionRevision
        return section(title: "Permissões", subtitle: "Acessibilidade intercepta o atalho e foca janelas; Gravação de Tela habilita as miniaturas.") {
            VStack(spacing: 8) {
                permissionRow(
                    title: "Acessibilidade",
                    detail: "Foca e restaura janelas",
                    granted: AccessibilityService.isTrusted,
                    actionTitle: "Abrir Ajustes",
                    action: onRequestAccessibility
                )
                if !AccessibilityService.isTrusted {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Se o Taber já aparece ativado nos Ajustes, desligue e ligue essa opção uma vez. Isso remove a autorização da build antiga.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button("Verificar novamente") {
                            permissionRevision += 1
                            monitor.refreshPermissions()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 7)
                }
                permissionRow(
                    title: "Gravação de Tela",
                    detail: "Exibe miniaturas do conteúdo",
                    granted: CGPreflightScreenCaptureAccess(),
                    actionTitle: "Abrir Ajustes",
                    action: onRequestScreenRecording
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("Privado por design — nenhuma janela sai do seu Mac", systemImage: "lock.fill")
            Spacer()
            Text("⌘ Tab • \(settings.searchShortcut.hint) buscar • \(settings.switcherStyle.directionalHint) • Esc")
                .font(.caption.monospaced())
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private func section<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func settingRow<Accessory: View>(
        icon: String,
        title: String,
        detail: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(palette.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
        .padding(.vertical, 12)
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Concedida")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button(actionTitle, action: action)
            }
        }
        .padding(13)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func symbol(for style: SwitcherStyle) -> String {
        switch style {
        case .preview: "rectangle.inset.filled.and.person.filled"
        case .list: "list.bullet.rectangle"
        case .icons: "square.grid.3x2.fill"
        case .flow: "rectangle.stack.fill"
        }
    }

    private func shortTitle(for style: SwitcherStyle) -> String {
        switch style {
        case .preview: "Miniaturas"
        case .list: "Lista"
        case .icons: "Ícones"
        case .flow: "Fluxo"
        }
    }

    private func shortDescription(for style: SwitcherStyle) -> String {
        switch style {
        case .preview: "Veja o conteúdo antes de trocar."
        case .list: "Mais janelas em menos espaço."
        case .icons: "Familiar e direto como o macOS."
        case .flow: "Prévia ampla com fila de troca rápida."
        }
    }
}
