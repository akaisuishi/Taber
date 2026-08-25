import Foundation

enum ShortcutMonitorState: Equatable {
    case disabled
    case needsAccessibility
    case active
    case failed

    var title: String {
        switch self {
        case .disabled: "Atalho desativado"
        case .needsAccessibility: "Acessibilidade necessária"
        case .active: "Command + Tab protegido"
        case .failed: "Não foi possível iniciar o atalho"
        }
    }

    var detail: String {
        switch self {
        case .disabled: "Ative o Taber para substituir o alternador padrão."
        case .needsAccessibility: "O macOS não reconheceu esta cópia do Taber como autorizada."
        case .active: "O Taber está interceptando o atalho e alternando janelas individuais."
        case .failed: "A permissão existe, mas o monitor global não pôde ser iniciado."
        }
    }

    var symbolName: String {
        switch self {
        case .active: "checkmark.shield.fill"
        case .disabled: "pause.circle.fill"
        case .needsAccessibility: "exclamationmark.shield.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}
