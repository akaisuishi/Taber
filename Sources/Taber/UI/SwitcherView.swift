import AppKit
import CoreGraphics
import SwiftUI

struct SwitcherView: View {
    @ObservedObject var model: SwitcherViewModel

    private var metrics: SwitcherMetrics { SwitcherMetrics(size: model.size) }

    var body: some View {
        let palette = model.theme.palette
        VStack(spacing: 0) {
            header
            if model.isSearching {
                searchBar
            }
            if model.isSearching && model.windows.isEmpty {
                emptySearchResult
            } else {
                Group {
                    switch model.style {
                    case .preview:
                        PreviewSwitcherView(
                            windows: model.windows,
                            selectedIndex: model.selectedIndex,
                            thumbnailGeneration: model.thumbnailGeneration,
                            size: model.size
                        )
                    case .list:
                        ListSwitcherView(
                            windows: model.windows,
                            selectedIndex: model.selectedIndex,
                            size: model.size
                        )
                    case .icons:
                        IconSwitcherView(
                            windows: model.windows,
                            selectedIndex: model.selectedIndex,
                            size: model.size
                        )
                    case .flow:
                        FlowSwitcherView(
                            windows: model.windows,
                            selectedIndex: model.selectedIndex,
                            thumbnailGeneration: model.thumbnailGeneration,
                            size: model.size
                        )
                    }
                }
            }
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: metrics.panelCornerRadius, style: .continuous)
                    .fill(palette.panel.opacity(0.97))
                RoundedRectangle(cornerRadius: metrics.panelCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                palette.accent.opacity(model.theme == .dark ? 0.035 : 0.12),
                                palette.accentSecondary.opacity(model.theme == .dark ? 0.02 : 0.08),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: metrics.panelCornerRadius, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
        .padding(4)
        .foregroundStyle(palette.primary)
        .environment(\.taberThemePalette, palette)
        .preferredColorScheme(model.theme.colorScheme)
    }

    private var header: some View {
        let palette = model.theme.palette
        return HStack(spacing: 8 * model.size.scale) {
            Image(systemName: "rectangle.3.group.fill")
                .foregroundStyle(palette.accent)
            Text("TABER")
                .font(.system(size: metrics.headerFont, weight: .bold, design: .rounded))
                .tracking(1.4 * model.size.scale)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if model.isSearching {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8 * model.size.scale) {
                        Text("digite para filtrar")
                        Text("⌫ apagar")
                        Text(model.isSearchDetached ? "↩ abrir" : "solte ⌘ para continuar")
                        Text("esc fechar")
                    }
                    Text(model.isSearchDetached ? "↩ abrir • esc fechar" : "solte ⌘ para continuar")
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8 * model.size.scale) {
                        Text(model.style.directionalHint)
                        Text("⇧ voltar")
                        Text("esc cancelar")
                    }
                    Text(model.style.directionalHint)
                    Text("⌘ Tab")
                }
            }
        }
        .font(.system(size: metrics.headerFont, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, metrics.headerHorizontalPadding)
        .padding(.top, metrics.headerTopPadding)
        .padding(.bottom, metrics.headerBottomPadding)
    }

    private var searchBar: some View {
        let palette = model.theme.palette
        return HStack(spacing: 9 * model.size.scale) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.accent)
            Text(model.searchQuery.isEmpty ? "Digite o nome da aplicação ou janela…" : model.searchQuery)
                .font(.system(size: metrics.titleFont, weight: model.searchQuery.isEmpty ? .regular : .semibold))
                .foregroundStyle(model.searchQuery.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(model.windows.count)")
                .font(.system(size: metrics.smallCaptionFont, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8 * model.size.scale)
                .padding(.vertical, 4 * model.size.scale)
                .background(palette.surface, in: Capsule())
        }
        .padding(.horizontal, 12 * model.size.scale)
        .frame(height: metrics.searchBarHeight - (6 * model.size.scale))
        .background(palette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 11 * model.size.scale))
        .overlay {
            RoundedRectangle(cornerRadius: 11 * model.size.scale)
                .stroke(palette.accent.opacity(0.42), lineWidth: 1)
        }
        .padding(.horizontal, metrics.contentHorizontalPadding)
        .padding(.bottom, 6 * model.size.scale)
    }

    private var emptySearchResult: some View {
        VStack(spacing: 8 * model.size.scale) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 24 * model.size.scale, weight: .medium))
            Text("Nenhuma janela encontrada")
                .font(.system(size: metrics.titleFont, weight: .semibold))
            Text("Continue digitando ou use ⌫ para corrigir.")
                .font(.system(size: metrics.captionFont))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, metrics.contentBottomPadding)
    }
}

private struct FlowSwitcherView: View {
    @Environment(\.taberThemePalette) private var palette
    let windows: [WindowInfo]
    let selectedIndex: Int
    let thumbnailGeneration: UInt
    let size: SwitcherSize

    private var metrics: SwitcherMetrics { SwitcherMetrics(size: size) }
    private var selectedWindow: WindowInfo? {
        windows.indices.contains(selectedIndex) ? windows[selectedIndex] : nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: metrics.itemSpacing) {
            focusStage
            if windows.count > 1 {
                focusQueue
            }
        }
        .padding(.horizontal, metrics.contentHorizontalPadding)
        .padding(.bottom, metrics.contentBottomPadding)
    }

    @ViewBuilder
    private var focusStage: some View {
        if let window = selectedWindow {
            let previewWidth = metrics.flowPreviewWidth(windowCount: windows.count)
            let previewHeight = metrics.flowPreviewHeight(windowCount: windows.count)
            VStack(alignment: .leading, spacing: 12 * size.scale) {
                ZStack(alignment: .topLeading) {
                    WindowThumbnail(
                        window: window,
                        width: previewWidth,
                        height: previewHeight,
                        generation: thumbnailGeneration,
                        size: size
                    )
                    Text(String(format: "%02d", selectedIndex + 1))
                        .font(.system(size: 12 * size.scale, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9 * size.scale)
                        .padding(.vertical, 6 * size.scale)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(12 * size.scale)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 13 * size.scale, style: .continuous)
                        .stroke(palette.accent.opacity(0.55), lineWidth: 1.5)
                }
                .shadow(color: palette.accent.opacity(0.18), radius: 18 * size.scale, y: 8 * size.scale)

                HStack(spacing: 11 * size.scale) {
                    Image(nsImage: window.icon ?? NSImage())
                        .resizable()
                        .scaledToFit()
                        .frame(width: 38 * size.scale, height: 38 * size.scale)
                    VStack(alignment: .leading, spacing: 3 * size.scale) {
                        Text(window.displayTitle)
                            .font(.system(size: metrics.flowTitleFont, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 7 * size.scale) {
                            Text(window.applicationName)
                                .lineLimit(1)
                            WindowSpaceBadge(window: window, fontSize: metrics.smallCaptionFont)
                        }
                        .font(.system(size: metrics.captionFont))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Solte ⌘", systemImage: "arrow.turn.down.left")
                        .font(.system(size: metrics.captionFont, weight: .semibold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 10 * size.scale)
                        .padding(.vertical, 7 * size.scale)
                        .background(palette.accent.opacity(0.10), in: Capsule())
                }
            }
            .frame(width: previewWidth)
        }
    }

    private var focusQueue: some View {
        VStack(alignment: .leading, spacing: 10 * size.scale) {
            HStack {
                VStack(alignment: .leading, spacing: 2 * size.scale) {
                    Text("FILA DE FOCO")
                        .font(.system(size: metrics.smallCaptionFont, weight: .bold, design: .rounded))
                        .tracking(1.2 * size.scale)
                    Text("Cada item representa uma janela")
                        .font(.system(size: metrics.smallCaptionFont))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(selectedIndex + 1)/\(windows.count)")
                    .font(.system(size: metrics.captionFont, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6 * size.scale) {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            FlowQueueRow(
                                window: window,
                                position: index + 1,
                                isSelected: index == selectedIndex,
                                size: size
                            )
                            .id(window.id)
                        }
                    }
                }
                .onAppear { scroll(to: selectedIndex, using: proxy, animated: false) }
                .onChange(of: selectedIndex) { _, value in scroll(to: value, using: proxy, animated: true) }
            }
        }
        .padding(12 * size.scale)
        .frame(width: metrics.flowQueueWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 15 * size.scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15 * size.scale, style: .continuous)
                .stroke(palette.border)
        }
    }

    private func scroll(to index: Int, using proxy: ScrollViewProxy, animated: Bool) {
        guard windows.indices.contains(index) else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.10)) {
                proxy.scrollTo(windows[index].id, anchor: .center)
            }
        } else {
            proxy.scrollTo(windows[index].id, anchor: .center)
        }
    }
}

private struct FlowQueueRow: View {
    @Environment(\.taberThemePalette) private var palette
    let window: WindowInfo
    let position: Int
    let isSelected: Bool
    let size: SwitcherSize

    private var metrics: SwitcherMetrics { SwitcherMetrics(size: size) }

    var body: some View {
        HStack(spacing: 9 * size.scale) {
            Text(String(format: "%02d", position))
                .font(.system(size: metrics.smallCaptionFont, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? palette.accent : palette.tertiary)
                .frame(width: 20 * size.scale)
            Image(nsImage: window.icon ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 28 * size.scale, height: 28 * size.scale)
            VStack(alignment: .leading, spacing: 1 * size.scale) {
                Text(window.displayTitle)
                    .font(.system(size: 12 * size.scale, weight: .semibold))
                    .lineLimit(1)
                Text(window.applicationName)
                    .font(.system(size: metrics.smallCaptionFont))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: window.spaceState.symbolName)
                .font(.system(size: metrics.smallCaptionFont, weight: .semibold))
                .foregroundStyle(spaceTint(for: window.spaceState, palette: palette))
                .help(window.spaceDescription)
        }
        .padding(.horizontal, 9 * size.scale)
        .padding(.vertical, 8 * size.scale)
        .background(selectionBackground(selected: isSelected, cornerRadius: metrics.cardCornerRadius))
    }
}

private struct PreviewSwitcherView: View {
    let windows: [WindowInfo]
    let selectedIndex: Int
    let thumbnailGeneration: UInt
    let size: SwitcherSize

    private var metrics: SwitcherMetrics { SwitcherMetrics(size: size) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        VStack(alignment: .leading, spacing: 7 * size.scale) {
                            WindowThumbnail(
                                window: window,
                                width: metrics.previewCardWidth,
                                height: metrics.previewHeight,
                                generation: thumbnailGeneration,
                                size: size
                            )
                            Text(window.displayTitle)
                                .font(.system(size: metrics.titleFont, weight: .semibold))
                                .lineLimit(1)
                            HStack(spacing: 6 * size.scale) {
                                Image(nsImage: window.icon ?? NSImage())
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14 * size.scale, height: 14 * size.scale)
                                Text(window.applicationName)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                WindowSpaceBadge(window: window, fontSize: metrics.smallCaptionFont)
                            }
                            .font(.system(size: metrics.smallCaptionFont))
                            .foregroundStyle(.secondary)
                        }
                        .frame(width: metrics.previewCardWidth, alignment: .leading)
                        .padding(metrics.cardPadding)
                        .background(
                            selectionBackground(
                                selected: index == selectedIndex,
                                cornerRadius: metrics.cardCornerRadius
                            )
                        )
                        .id(window.id)
                    }
                }
                .padding(.horizontal, metrics.contentHorizontalPadding)
                .padding(.bottom, metrics.contentBottomPadding)
            }
            .onAppear { scroll(to: selectedIndex, using: proxy, animated: false) }
            .onChange(of: selectedIndex) { _, value in scroll(to: value, using: proxy, animated: true) }
        }
    }

    private func scroll(to index: Int, using proxy: ScrollViewProxy, animated: Bool) {
        guard windows.indices.contains(index) else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.10)) {
                proxy.scrollTo(windows[index].id, anchor: .center)
            }
        } else {
            proxy.scrollTo(windows[index].id, anchor: .center)
        }
    }
}

private struct ListSwitcherView: View {
    let windows: [WindowInfo]
    let selectedIndex: Int
    let size: SwitcherSize

    private var metrics: SwitcherMetrics { SwitcherMetrics(size: size) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 5 * size.scale) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        HStack(spacing: 12 * size.scale) {
                            Image(nsImage: window.icon ?? NSImage())
                                .resizable()
                                .scaledToFit()
                                .frame(width: metrics.listIconSize, height: metrics.listIconSize)
                            VStack(alignment: .leading, spacing: 2 * size.scale) {
                                Text(window.displayTitle)
                                    .font(.system(size: metrics.listTitleFont, weight: .semibold))
                                    .lineLimit(1)
                                Text(window.applicationName)
                                    .font(.system(size: metrics.captionFont))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            WindowSpaceBadge(window: window, fontSize: metrics.smallCaptionFont)
                        }
                        .padding(.horizontal, 13 * size.scale)
                        .padding(.vertical, 9 * size.scale)
                        .background(
                            selectionBackground(
                                selected: index == selectedIndex,
                                cornerRadius: metrics.cardCornerRadius
                            )
                        )
                        .id(window.id)
                    }
                }
                .padding(.horizontal, 12 * size.scale)
                .padding(.bottom, metrics.contentBottomPadding)
            }
            .onAppear { scroll(to: selectedIndex, using: proxy, animated: false) }
            .onChange(of: selectedIndex) { _, value in scroll(to: value, using: proxy, animated: true) }
        }
    }

    private func scroll(to index: Int, using proxy: ScrollViewProxy, animated: Bool) {
        guard windows.indices.contains(index) else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.10)) {
                proxy.scrollTo(windows[index].id, anchor: .center)
            }
        } else {
            proxy.scrollTo(windows[index].id, anchor: .center)
        }
    }
}

private struct IconSwitcherView: View {
    @Environment(\.taberThemePalette) private var palette
    let windows: [WindowInfo]
    let selectedIndex: Int
    let size: SwitcherSize

    private var metrics: SwitcherMetrics { SwitcherMetrics(size: size) }

    var body: some View {
        let counts = Dictionary(grouping: windows, by: \.applicationIdentifier).mapValues(\.count)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: metrics.itemSpacing) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        VStack(spacing: 5 * size.scale) {
                            ZStack(alignment: .bottomTrailing) {
                                Image(nsImage: window.icon ?? NSImage())
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: metrics.iconSize, height: metrics.iconSize)
                                if counts[window.applicationIdentifier, default: 0] > 1 {
                                    Text("\(ordinal(for: index))")
                                        .font(.system(size: metrics.smallCaptionFont, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .frame(width: 17 * size.scale, height: 17 * size.scale)
                                        .background(palette.accent, in: Circle())
                                }
                            }
                            Text(window.applicationName)
                                .font(.system(size: metrics.smallCaptionFont))
                                .lineLimit(1)
                                .frame(width: metrics.iconItemWidth)
                            WindowSpaceBadge(
                                window: window,
                                fontSize: max(8, metrics.smallCaptionFont - 1),
                                compact: true
                            )
                        }
                        .frame(width: metrics.iconItemWidth)
                        .padding(metrics.cardPadding)
                        .background(
                            selectionBackground(
                                selected: index == selectedIndex,
                                cornerRadius: metrics.cardCornerRadius
                            )
                        )
                        .id(window.id)
                        .help("\(window.displayTitle) · \(window.spaceDescription)")
                    }
                }
                .padding(.horizontal, metrics.contentHorizontalPadding)
                .padding(.bottom, metrics.contentBottomPadding)
            }
            .onAppear { scroll(to: selectedIndex, using: proxy, animated: false) }
            .onChange(of: selectedIndex) { _, value in scroll(to: value, using: proxy, animated: true) }
        }
    }

    private func ordinal(for index: Int) -> Int {
        let identifier = windows[index].applicationIdentifier
        return windows[..<index].lazy.filter { $0.applicationIdentifier == identifier }.count + 1
    }

    private func scroll(to index: Int, using proxy: ScrollViewProxy, animated: Bool) {
        guard windows.indices.contains(index) else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.10)) {
                proxy.scrollTo(windows[index].id, anchor: .center)
            }
        } else {
            proxy.scrollTo(windows[index].id, anchor: .center)
        }
    }
}

private struct WindowSpaceBadge: View {
    @Environment(\.taberThemePalette) private var palette
    let window: WindowInfo
    let fontSize: CGFloat
    var compact = false

    var body: some View {
        Label {
            Text(window.spaceLabel)
                .lineLimit(1)
        } icon: {
            Image(systemName: window.spaceState.symbolName)
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(spaceTint(for: window.spaceState, palette: palette))
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(spaceTint(for: window.spaceState, palette: palette).opacity(0.10), in: Capsule())
        .help(window.spaceDescription)
    }
}

private struct WindowThumbnail: View {
    @Environment(\.taberThemePalette) private var palette
    let window: WindowInfo
    var width: CGFloat = 220
    var height: CGFloat = 132
    let generation: UInt
    let size: SwitcherSize
    @State private var result: WindowThumbnailResult?

    var body: some View {
        ZStack {
            palette.thumbnailBackground
            if case let .image(image) = result {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9 * size.scale, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9 * size.scale, style: .continuous)
                .stroke(palette.border)
        }
        .task(id: ThumbnailRequestID(windowID: window.id, generation: generation)) {
            result = nil
            result = await WindowThumbnailService.shared.thumbnail(
                for: window,
                targetSize: CGSize(width: width, height: height),
                generation: generation
            )
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8 * size.scale) {
            switch result {
            case nil:
                ProgressView()
                    .controlSize(.small)
                Text("Carregando conteúdo…")
                    .font(.system(size: 10 * size.scale))
                    .foregroundStyle(.secondary)
            case .permissionRequired:
                Image(systemName: "record.circle")
                    .font(.system(size: 31 * size.scale, weight: .medium))
                    .foregroundStyle(palette.accent)
                Text("Autorize Gravação de Tela")
                    .font(.system(size: 11 * size.scale, weight: .semibold))
                Text("Abra as configurações do Taber")
                    .font(.system(size: 10 * size.scale))
                    .foregroundStyle(.secondary)
            case .unavailable:
                Image(nsImage: window.icon ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48 * size.scale, height: 48 * size.scale)
                Text(unavailableMessage)
                    .font(.system(size: 10 * size.scale))
                    .foregroundStyle(.secondary)
            case .image:
                EmptyView()
            }
        }
        .multilineTextAlignment(.center)
        .padding(12 * size.scale)
    }

    private var unavailableMessage: String {
        if window.isMinimized { return "Conteúdo indisponível enquanto minimizada" }
        if window.isFullScreen { return "Conteúdo protegido em Tela Cheia" }
        return "Conteúdo protegido ou indisponível"
    }
}

private struct ThumbnailRequestID: Hashable {
    let windowID: CGWindowID
    let generation: UInt
}

private func spaceTint(for state: WindowSpaceState, palette: TaberThemePalette) -> Color {
    switch state {
    case .current: palette.accent
    case .another: palette.accentSecondary
    case .minimized: .orange
    case .fullScreen: .green
    }
}

@ViewBuilder
private func selectionBackground(selected: Bool, cornerRadius: CGFloat) -> some View {
    SelectionBackground(selected: selected, cornerRadius: cornerRadius)
}

private struct SelectionBackground: View {
    @Environment(\.taberThemePalette) private var palette
    let selected: Bool
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(selected ? AnyShapeStyle(palette.selection) : AnyShapeStyle(palette.surface))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(selected ? palette.accent.opacity(0.65) : palette.border, lineWidth: 1)
            }
    }
}
