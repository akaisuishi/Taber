import AppKit
import CoreGraphics
import os
@preconcurrency import ScreenCaptureKit

enum WindowThumbnailResult: @unchecked Sendable {
    case image(NSImage)
    case permissionRequired
    case unavailable
}

struct ThumbnailRequestBudget {
    private(set) var generation: UInt = 0
    private(set) var active = 0
    let limit = 6
    mutating func begin() { generation &+= 1 }
    mutating func acquire() -> UInt? {
        guard active < limit else { return nil }
        active += 1
        return generation
    }
    mutating func release() { active = max(0, active - 1) }
    func accepts(_ token: UInt) -> Bool { token == generation }
}

/// Suspends overflow requests instead of dropping their previews. No polling.
@MainActor
final class ThumbnailCaptureQueue {
    private var active = 0
    private var generation: UInt = 0
    private var waiters: [(UInt, CheckedContinuation<Bool, Never>)] = []
    let limit: Int
    init(limit: Int = 3) { self.limit = max(1, limit) }
    func begin() {
        generation &+= 1
        let old = waiters; waiters.removeAll()
        for (_, continuation) in old { continuation.resume(returning: false) }
    }
    var token: UInt { generation }
    func accepts(_ token: UInt) -> Bool { token == generation }
    func acquire(_ token: UInt) async -> Bool {
        guard accepts(token), !Task.isCancelled else { return false }
        if active < limit { active += 1; return true }
        return await withCheckedContinuation { waiters.append((token, $0)) }
    }
    func release() {
        active -= 1
        while !waiters.isEmpty {
            let (token, continuation) = waiters.removeFirst()
            if accepts(token) { active += 1; continuation.resume(returning: true); return }
            continuation.resume(returning: false)
        }
    }
}

private final class ThumbnailCacheEntry {
    let image: NSImage
    let capturedAt: TimeInterval
    init(_ image: NSImage, at time: TimeInterval) { self.image = image; capturedAt = time }
}

@MainActor
final class WindowThumbnailService {
    static let shared = WindowThumbnailService()

    private let cache = NSCache<NSString, ThumbnailCacheEntry>()
    private let logger = Logger(subsystem: "com.taber.app", category: "thumbnails")
    private var shareableWindows: [CGWindowID: SCWindow] = [:]
    private var shareableContentTask: Task<SCShareableContent, Error>?
    private var shareableContentTaskID: UUID?
    private var lastContentRefresh = Date.distantPast
    private let captureQueue = ThumbnailCaptureQueue()
    private var inFlight: [String: Task<WindowThumbnailResult, Never>] = [:]
    private var contentEpoch: UInt = 0

    private let permission: () -> Bool
    private let now: () -> TimeInterval
    private let prepareCapture: ((WindowInfo) async throws -> Void)?
    private let captureOverride: ((WindowInfo, CGSize) async throws -> CGImage)?

    init(permission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         prepare: ((WindowInfo) async throws -> Void)? = nil,
         capture: ((WindowInfo, CGSize) async throws -> CGImage)? = nil) {
        self.permission = permission; self.now = now; self.captureOverride = capture; self.prepareCapture = prepare
        cache.totalCostLimit = 128 * 1_024 * 1_024
        cache.countLimit = 48
    }

    func thumbnail(
        for window: WindowInfo,
        targetSize: CGSize,
        generation: UInt
    ) async -> WindowThumbnailResult {
        _ = generation
        guard permission() else { return .permissionRequired }
        let key = Self.requestKey(window, targetSize)
        if let cached = cache.object(forKey: key as NSString),
           now() - cached.capturedAt < 1.5 { return .image(cached.image) }
        let token = captureQueue.token
        let flightKey = "\(token):\(key)"
        if let task = inFlight[flightKey] { return await task.value }
        let task = Task { await self.capture(window, targetSize: targetSize, key: key, token: token) }
        inFlight[flightKey] = task
        let result = await task.value
        inFlight[flightKey] = nil
        return result
    }

    func cachedThumbnail(for window: WindowInfo, targetSize: CGSize) -> WindowThumbnailResult? {
        guard permission() else { return .permissionRequired }
        guard let entry = cache.object(forKey: Self.requestKey(window, targetSize) as NSString),
              now() - entry.capturedAt < 30 else { return nil }
        return .image(entry.image)
    }

    static func requestKey(_ window: WindowInfo, _ size: CGSize) -> String {
        // Quantization avoids new captures for fractional layout changes.
        let width = Int((max(1, size.width) / 32).rounded(.up)) * 32
        let height = Int((max(1, size.height) / 32).rounded(.up)) * 32
        return "\(window.id):\(window.processLaunchDate?.timeIntervalSince1970 ?? 0):\(window.presentationWindowID ?? 0):\(width)x\(height)"
    }

    private func capture(_ window: WindowInfo, targetSize: CGSize, key: String, token: UInt) async -> WindowThumbnailResult {
        guard !Task.isCancelled, captureQueue.accepts(token) else { return .unavailable }
        // Catalog discovery/retries do not occupy screenshot slots.
        var resolvedWindow: SCWindow?
        do {
            if let prepareCapture { try await prepareCapture(window) }
            if captureOverride == nil {
                guard let id = window.presentationWindowID ?? window.windowServerID else { return .unavailable }
                resolvedWindow = try await shareableWindow(withID: id)
                guard resolvedWindow != nil else { return .unavailable }
            }
        } catch { return .unavailable }
        guard await captureQueue.acquire(token) else { return .unavailable }
        defer { captureQueue.release() }
        guard !Task.isCancelled, captureQueue.accepts(token) else { return .unavailable }
        let captureStartedAt = ContinuousClock.now

        guard permission() else {
            logger.notice("Captura bloqueada: Gravação de Tela não foi concedida para esta assinatura")
            return .permissionRequired
        }

        do {
            let cgImage: CGImage
            if let captureOverride {
                cgImage = try await captureOverride(window, targetSize)
            } else {
                guard let captureWindow = resolvedWindow,
                      captureWindow.owningApplication?.processID == window.ownerPID else { return .unavailable }

            let filter = SCContentFilter(desktopIndependentWindow: captureWindow)
            let configuration = captureConfiguration(
                for: captureWindow,
                targetSize: targetSize
            )
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            }
            guard !Task.isCancelled, captureQueue.accepts(token) else { return .unavailable }
            let image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            cache.setObject(ThumbnailCacheEntry(image, at: now()), forKey: key as NSString, cost: cgImage.bytesPerRow * cgImage.height)
            let elapsed = captureStartedAt.duration(to: .now)
            let elapsedMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            TaberDiagnostics.record("thumbnailCaptured", fields: [
                "target": TaberDiagnostics.identity(window),
                "width": cgImage.width,
                "height": cgImage.height,
                "elapsedMs": elapsedMs
            ])
            logger.notice(
                "Miniatura capturada: janela=\(window.id) pixels=\(cgImage.width)x\(cgImage.height) duração=\(String(describing: elapsed), privacy: .public)"
            )
            return .image(image)
        } catch {
            guard !Task.isCancelled, captureQueue.accepts(token) else { return .unavailable }
            logger.error("Falha ao capturar janela \(window.id): \(error.localizedDescription, privacy: .public)")
            invalidateShareableContent()
            return .unavailable
        }
    }

    func beginPresentation() {
        captureQueue.begin()
        // Keep recent images and a catalog request already in progress.
    }

    func endPresentation() {
        captureQueue.begin()
        for task in inFlight.values { task.cancel() }
    }

    private func shareableWindow(withID windowID: CGWindowID, retryMissing: Bool = true) async throws -> SCWindow? {
        let epoch = contentEpoch
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
            shareableContentTaskID = UUID()
            shareableContentTask = newTask
            task = newTask
        }

        let taskID = shareableContentTaskID
        let content: SCShareableContent
        do { content = try await task.value }
        catch {
            if taskID == shareableContentTaskID { shareableContentTask = nil; shareableContentTaskID = nil }
            throw error
        }
        guard epoch == contentEpoch else { throw CancellationError() }
        if taskID == shareableContentTaskID {
            shareableWindows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            lastContentRefresh = Date()
            shareableContentTask = nil; shareableContentTaskID = nil
        }
        if let window = content.windows.first(where: { $0.windowID == windowID }) { return window }
        if retryMissing {
            try await Task.sleep(for: .seconds(2))
            return try await shareableWindow(withID: windowID, retryMissing: false)
        }
        return nil
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
        contentEpoch &+= 1
        shareableContentTask?.cancel()
        shareableWindows = [:]
        lastContentRefresh = .distantPast
        shareableContentTask = nil
    }
}
