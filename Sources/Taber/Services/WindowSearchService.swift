import Foundation

enum WindowSearchService {
    static func results(in windows: [WindowInfo], query: String) -> [WindowInfo] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else { return windows }
        let terms = normalizedQuery.split(whereSeparator: \.isWhitespace).map(String.init)

        return windows.enumerated().compactMap { index, window -> (WindowInfo, Int, Int)? in
            let application = normalized(window.applicationName)
            let title = normalized(window.displayTitle)
            let searchable = "\(application) \(title)"
            guard terms.allSatisfy(searchable.contains) else { return nil }

            var score = 0
            if application == normalizedQuery { score += 140 }
            if application.hasPrefix(normalizedQuery) { score += 100 }
            if title.hasPrefix(normalizedQuery) { score += 80 }
            if application.contains(normalizedQuery) { score += 45 }
            if title.contains(normalizedQuery) { score += 30 }
            return (window, score, index)
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 > rhs.1
        }
        .map(\.0)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
