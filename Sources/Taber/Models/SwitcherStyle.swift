import Foundation

enum SwitcherNavigationAxis {
    case horizontal
    case vertical
}

enum SwitcherStyle: String, CaseIterable, Identifiable {
    case preview
    case list
    case icons
    case flow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: "Miniaturas das janelas"
        case .list: "Lista compacta"
        case .icons: "Ícones das aplicações"
        case .flow: "Fluxo produtivo"
        }
    }

    var description: String {
        switch self {
        case .preview: "Exibe uma miniatura do conteúdo de cada janela."
        case .list: "Exibe as janelas em uma lista vertical com ícone, aplicação e título."
        case .icons: "Exibe somente os ícones, mantendo cada janela como uma opção separada."
        case .flow: "Combina uma prévia ampla da seleção com uma fila rápida de todas as janelas."
        }
    }

    var navigationAxis: SwitcherNavigationAxis {
        switch self {
        case .preview, .icons: .horizontal
        case .list, .flow: .vertical
        }
    }

    var directionalHint: String {
        switch navigationAxis {
        case .horizontal: "←→ navegar"
        case .vertical: "↑↓ navegar"
        }
    }
}
