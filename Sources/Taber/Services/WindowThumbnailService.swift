import AppKit
import CoreGraphics
import os
@preconcurrency import ScreenCaptureKit

enum WindowThumbnailResult {
    case image(NSImage)
    case permissionRequired
    case unavailable
}

@MainActor
final class WindowThumbnailService {
    static let shared = WindowThumbnailService()

    private let cache = NSCache<NSString, NSImage>()
    private let logger = Logger(subsystem: "com.taber.app", category: "thumbnails")
    private var shareableWindows: [CGWindowID: SCWindow] = [:]
    private var shareableContentTask: Task<SCShareableContent, Error>?
    private var lastContentRefresh = Date.distantPast
    private var thumbnailCacheGeneration: UInt = 0
    private var lastThumbnailGenerationRefresh = Date.distantPast

    private init() {
        cache.totalCostLimit = 128 * 1_024 * 1_024
        cache.countLimit = 48
    }

    func thumbnail(
        for window: WindowInfo,
        targetSize: CGSize,
        generation: UInt
    ) async -> WindowThumbnailResult {
        // `generation` ainda força o SwiftUI a reiniciar a tarefa de cada
        // cartão, enquanto a geração interna permite reaproveitar por um
        // intervalo curto a mesma imagem em Command+Tab consecutivos.
        _ = generation
        let key = "\(thumbnailCacheGeneration):\(window.id):\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        if let cached = cache.object(forKey: key) {
            return .image(cached)
        }

        let captureStartedAt = ContinuousClock.now

        guard CGPreflightScreenCaptureAccess() else {
            logger.notice("Captura bloqueada: Gravação de Tela não foi concedida para esta assinatura")
            return .permissionRequired
        }

        do {
            guard let captureWindow = try await shareableWindow(withID: window.id) else {
                logger.notice("Janela \(window.id) não foi disponibilizada pelo ScreenCaptureKit")
                return .unavailable
            }

            let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
            let configuration = captureConfiguration(
                for: captureWindow,
                targetSize: targetSize
            )
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
            let elapsed = captureStartedAt.duration(to: .now)
            logger.notice(
                "Miniatura capturada: janela=\(window.id) pixels=\(cgImage.width)x\(cgImage.height) duração=\(String(describing: elapsed), privacy: .public)"
            )
            return .image(image)
        } catch {
            logger.error("Falha ao capturar janela \(window.id): \(error.localizedDescription, privacy: .public)")
            invalidateShareableContent()
            return .unavailable
        }
    }

    func beginPresentation() {
        let now = Date()
        if now.timeIntervalSince(lastThumbnailGenerationRefresh) >= 1.5 {
            thumbnailCacheGeneration &+= 1
            lastThumbnailGenerationRefresh = now
        }
        // A geração do ViewModel reinicia as tarefas visuais. O catálogo de
        // janelas e miniaturas ainda recentes podem ser reutilizados em
        // alternâncias consecutivas, evitando trabalho caro a cada Tab.
        // Janelas novas que não estejam no catálogo ainda provocam refresh
        // imediato em shareableWindow(withID:).
        if Date().timeIntervalSince(lastContentRefresh) >= 2 {
            invalidateShareableContent()
        }
    }

    private func shareableWindow(withID windowID: CGWindowID) async throws -> SCWindow? {
        if Date().timeIntervalSince(lastContentRefresh) < 2,
           let window = shareableWindows[windowID] {
            return window
        }

        let task: Task<SCShareableContent, Error>
        if let shareableContentTask {
            task = shareableContentTask
        } else {
            let newTask = Task {
                try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
            }
            shareableContentTask = newTask
            task = newTask
        }

        do {
            let content = try await task.value
            shareableWindows = Dictionary(
                uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) }
            )
            lastContentRefresh = Date()
            shareableContentTask = nil
            return shareableWindows[windowID]
        } catch {
            shareableContentTask = nil
            throw error
        }
    }

    private func captureConfiguration(
        for window: SCWindow,
        targetSize: CGSize
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let sourceWidth = max(window.frame.width, 1)
        let sourceHeight = max(window.frame.height, 1)
        let targetPixelWidth = max(320, min(targetSize.width * 2, 1_280))
        let targetPixelHeight = max(180, min(targetSize.height * 2, 800))
        let pixelScale = min(
            2,
            targetPixelWidth / sourceWidth,
            targetPixelHeight / sourceHeight
        )

        configuration.width = max(64, Int(sourceWidth * pixelScale))
        configuration.height = max(64, Int(sourceHeight * pixelScale))
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return configuration
    }

    private func invalidateShareableContent() {
        shareableWindows = [:]
        lastContentRefresh = .distantPast
        shareableContentTask = nil
    }
}
