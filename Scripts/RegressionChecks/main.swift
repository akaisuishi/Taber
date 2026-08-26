import CoreGraphics
import Foundation

private struct RegressionFailure: Error {
    let message: String
}

private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    checks += 1
    guard condition() else { throw RegressionFailure(message: message) }
}

do {
    try expect(
        WindowMatchingPolicy.uniqueIdentifierIndex(
            targetIdentifier: "FinderWindow",
            candidateIdentifiers: ["FinderWindow", "FinderWindow"]
        ) == nil,
        "um identificador repetido do Finder não pode escolher a primeira janela"
    )

    try expect(
        WindowMatchingPolicy.uniqueIdentifierIndex(
            targetIdentifier: "unique-window",
            candidateIdentifiers: ["other", "unique-window"]
        ) == 1,
        "um identificador realmente único deve continuar sendo usado"
    )

    let commonBounds = CGRect(x: 100, y: 80, width: 1280, height: 720)
    try expect(
        WindowMatchingPolicy.fallbackScore(
            candidateTitle: "Aba A",
            candidateBounds: commonBounds,
            candidateIsMinimized: false,
            candidateOrdinal: 0,
            accessibilityTitle: "Aba B",
            accessibilityBounds: CGRect(x: 400, y: 300, width: 800, height: 600),
            accessibilityIsMinimized: false,
            accessibilityOrdinal: 0
        ) == nil,
        "a mesma posição na lista não pode ser tratada como identidade"
    )

    try expect(
        WindowMatchingPolicy.fallbackScore(
            candidateTitle: "Relatório",
            candidateBounds: commonBounds,
            candidateIsMinimized: false,
            candidateOrdinal: 3,
            accessibilityTitle: "relatorio",
            accessibilityBounds: CGRect(x: 500, y: 300, width: 600, height: 400),
            accessibilityIsMinimized: false,
            accessibilityOrdinal: 0
        ) != nil,
        "títulos equivalentes devem reconciliar uma janela fora de ordem"
    )

    try expect(
        WindowMatchingPolicy.requiresApplicationActivation(
            isPresentationSized: true,
            candidateTitle: "YouTube",
            candidateBounds: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            accessibilityTitle: "YouTube",
            accessibilityBounds: CGRect(x: 80, y: 80, width: 1200, height: 800)
        ),
        "uma superfície de vídeo separada deve reativar o navegador sem levantar a janela-base"
    )

    try expect(
        !WindowMatchingPolicy.requiresApplicationActivation(
            isPresentationSized: true,
            candidateTitle: "Safari",
            candidateBounds: commonBounds,
            accessibilityTitle: "Safari",
            accessibilityBounds: commonBounds
        ),
        "uma janela maximizada correspondente deve ser levantada normalmente"
    )

    try expect(
        !WindowMatchingPolicy.requiresApplicationActivation(
            isPresentationSized: true,
            hasExactWindowIDMatch: true,
            candidateTitle: "Nova guia anônima",
            candidateBounds: CGRect(x: 0, y: 39, width: 1710, height: 1015),
            accessibilityTitle: "Nova guia anônima",
            accessibilityBounds: CGRect(x: 0, y: 39, width: 1710, height: 1073)
        ),
        "uma janela maximizada do Chrome com ID exato não pode virar fullscreen de conteúdo"
    )

    try expect(
        WindowMatchingPolicy.requiresApplicationActivation(
            isPresentationSized: true,
            hasExactWindowIDMatch: true,
            isDialog: true,
            candidateTitle: "YouTube",
            candidateBounds: CGRect(x: 0, y: 0, width: 1710, height: 1112),
            accessibilityTitle: "YouTube",
            accessibilityBounds: CGRect(x: 0, y: 0, width: 1710, height: 1112)
        ),
        "um AXDialog de mídia deve preservar a ativação do navegador"
    )

    try expect(
        !WindowMatchingPolicy.requiresApplicationActivation(
            isPresentationSized: false,
            candidateTitle: "YouTube",
            candidateBounds: commonBounds,
            accessibilityTitle: "Outra janela",
            accessibilityBounds: .zero
        ),
        "uma janela comum nunca deve ser confundida com uma apresentação fullscreen"
    )

    try expect(
        WindowMatchingPolicy.isDetachedPresentationCandidate(
            isPresentationSized: true,
            candidateWindowID: 900,
            accessibilityWindowIDs: [101, 102],
            fallbackRequiresApplicationActivation: false
        ),
        "um player fullscreen sem janela AX própria deve ser associado à janela hospedeira"
    )

    try expect(
        !WindowMatchingPolicy.isDetachedPresentationCandidate(
            isPresentationSized: true,
            candidateWindowID: 101,
            accessibilityWindowIDs: [101, 102],
            fallbackRequiresApplicationActivation: true
        ),
        "uma janela fullscreen com identidade AX própria não é uma superfície destacada"
    )

    try expect(
        WindowMatchingPolicy.preferredContentHostIndex(
            presentationOrdinal: 0,
            presentationDocument: "https://video.example/watch",
            candidates: [
                (index: 1, ordinal: 2, document: "https://other.example"),
                (index: 2, ordinal: 3, document: "https://video.example/watch")
            ]
        ) == 2,
        "o documento do player deve identificar sua janela-base entre várias janelas do navegador"
    )

    try expect(
        WindowMatchingPolicy.preferredContentHostIndex(
            presentationOrdinal: 0,
            presentationDocument: "",
            candidates: [
                (index: 4, ordinal: 3, document: ""),
                (index: 5, ordinal: 1, document: "")
            ]
        ) == 5,
        "sem documento, a janela AX adjacente é o fallback mais seguro para o host"
    )

    print("PASSOU: \(checks) verificações de regressão")
} catch let failure as RegressionFailure {
    fputs("FALHOU: \(failure.message)\n", stderr)
    exit(1)
}
