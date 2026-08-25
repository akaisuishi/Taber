import Foundation

enum SearchShortcut: String, CaseIterable, Identifiable {
    case doubleShift
    case space
    case letterF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doubleShift: "Shift duas vezes"
        case .space: "Barra de espaço"
        case .letterF: "Tecla F"
        }
    }

    var hint: String {
        switch self {
        case .doubleShift: "⇧ ⇧"
        case .space: "Espaço"
        case .letterF: "F"
        }
    }

    var keyCode: Int64? {
        switch self {
        case .doubleShift: nil
        case .space: 49
        case .letterF: 3
        }
    }
}
