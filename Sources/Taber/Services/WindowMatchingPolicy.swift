import CoreGraphics
import Foundation

enum WindowMatchingPolicy {
    static func fallbackScore(
        candidateTitle: String,
        candidateBounds: CGRect,
        candidateIsMinimized: Bool,
        candidateOrdinal: Int,
        accessibilityTitle: String,
        accessibilityBounds: CGRect?,
        accessibilityIsMinimized: Bool,
        accessibilityOrdinal: Int
    ) -> Int? {
        let normalizedCandidateTitle = normalized(candidateTitle)
        let normalizedAccessibilityTitle = normalized(accessibilityTitle)
        let titleMatches = !normalizedCandidateTitle.isEmpty
            && normalizedCandidateTitle == normalizedAccessibilityTitle
        let geometryMatches = accessibilityBounds.map {
            approximatelyEqual(candidateBounds, $0, tolerance: 8)
        } ?? false
        let exactGeometryMatches = accessibilityBounds.map {
            approximatelyEqual(candidateBounds, $0, tolerance: 3)
        } ?? false

        // A ordem visual muda quando uma janela é minimizada, troca de Space
        // ou quando um player cria uma superfície própria. Ela serve apenas
        // para desempate, nunca como prova de identidade.
        guard titleMatches || geometryMatches else { return nil }

        let ordinalDistance = abs(candidateOrdinal - accessibilityOrdinal)
        var score = 0
        if geometryMatches { score += 500 }
        if exactGeometryMatches { score += 120 }
        if titleMatches { score += 180 }
        if candidateIsMinimized == accessibilityIsMinimized { score += 20 }
        score += max(0, 30 - ordinalDistance)
        return score
    }

    static func uniqueIdentifierIndex(
        targetIdentifier: String,
        candidateIdentifiers: [String]
    ) -> Int? {
        guard !targetIdentifier.isEmpty else { return nil }
        let matches = candidateIdentifiers.indices.filter {
            candidateIdentifiers[$0] == targetIdentifier
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func requiresApplicationActivation(
        isPresentationSized: Bool,
        candidateTitle: String,
        candidateBounds: CGRect,
        accessibilityTitle: String,
        accessibilityBounds: CGRect
    ) -> Bool {
        guard isPresentationSized else { return false }
        let geometryMatches = approximatelyEqual(
            candidateBounds,
            accessibilityBounds,
            tolerance: 8
        )
        let normalizedCandidateTitle = normalized(candidateTitle)
        let normalizedAccessibilityTitle = normalized(accessibilityTitle)
        let titleIdentifiesSameWindow = !normalizedCandidateTitle.isEmpty
            && (normalizedAccessibilityTitle.isEmpty
                || normalizedCandidateTitle == normalizedAccessibilityTitle)
        return !(geometryMatches && titleIdentifiesSameWindow)
    }

    static func isDetachedPresentationCandidate(
        isPresentationSized: Bool,
        candidateWindowID: CGWindowID,
        accessibilityWindowIDs: [CGWindowID?],
        fallbackRequiresApplicationActivation: Bool
    ) -> Bool {
        guard isPresentationSized else { return false }
        let knownWindowIDs = accessibilityWindowIDs.compactMap { $0 }
        if !knownWindowIDs.isEmpty {
            return !knownWindowIDs.contains(candidateWindowID)
        }
        return fallbackRequiresApplicationActivation
    }

    static func preferredContentHostIndex(
        presentationOrdinal: Int,
        presentationDocument: String,
        candidates: [(index: Int, ordinal: Int, document: String)]
    ) -> Int? {
        guard !candidates.isEmpty else { return nil }
        if !presentationDocument.isEmpty {
            let documentMatches = candidates.filter {
                $0.document == presentationDocument
            }
            if documentMatches.count == 1 {
                return documentMatches[0].index
            }
        }
        return candidates.min {
            abs($0.ordinal - presentationOrdinal) < abs($1.ordinal - presentationOrdinal)
        }?.index
    }

    static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
