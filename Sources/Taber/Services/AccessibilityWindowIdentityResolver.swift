@preconcurrency import ApplicationServices
import CoreGraphics
import Darwin

/// Conecta uma janela AX à superfície correspondente do WindowServer.
///
/// O macOS não oferece uma API pública equivalente. A função é carregada de
/// forma opcional para que o Taber continue funcionando com a reconciliação
/// conservadora caso ela deixe de estar disponível em uma versão futura.
enum AccessibilityWindowIdentityResolver {
    private typealias WindowIDFunction = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private static let windowIDFunction: WindowIDFunction? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
            RTLD_LAZY | RTLD_LOCAL
        ), let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    static var isAvailable: Bool {
        windowIDFunction != nil
    }

    static func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let windowIDFunction else { return nil }
        var windowID: CGWindowID = 0
        guard windowIDFunction(element, &windowID) == .success,
              windowID != 0
        else { return nil }
        return windowID
    }
}
