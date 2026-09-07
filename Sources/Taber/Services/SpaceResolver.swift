import CoreGraphics
import Darwin
import Foundation
import os

struct ResolvedWindowSpace {
    let identifier: UInt64
    let number: Int?
    let isFullScreen: Bool
}

@MainActor
final class SpaceResolver {
    static let shared = SpaceResolver()

    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias CopyManagedSpacesFunction = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFunction = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    struct ManagedSpace {
        let number: Int?
        let isFullScreen: Bool
    }

    private let connection: Int32?
    private let copyManagedSpaces: CopyManagedSpacesFunction?
    private let copySpacesForWindows: CopySpacesForWindowsFunction?
    private let logger = Logger(subsystem: "com.taber.app", category: "spaces")

    private init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL
        ),
        let mainSymbol = dlsym(handle, "SLSMainConnectionID"),
        let managedSymbol = dlsym(handle, "SLSCopyManagedDisplaySpaces"),
        let windowsSymbol = dlsym(handle, "SLSCopySpacesForWindows")
        else {
            connection = nil
            copyManagedSpaces = nil
            copySpacesForWindows = nil
            logger.warning("Numeração de Spaces indisponível; usando estado semântico")
            return
        }

        let mainConnection = unsafeBitCast(mainSymbol, to: MainConnectionFunction.self)
        connection = mainConnection()
        copyManagedSpaces = unsafeBitCast(managedSymbol, to: CopyManagedSpacesFunction.self)
        copySpacesForWindows = unsafeBitCast(windowsSymbol, to: CopySpacesForWindowsFunction.self)
    }

    func resolve(windowIDs: [CGWindowID]) -> [CGWindowID: ResolvedWindowSpace] {
        guard let connection,
              let copyManagedSpaces,
              let copySpacesForWindows,
              let managedArray = copyManagedSpaces(connection)?.takeRetainedValue(),
              let displays = managedArray as? [[String: Any]]
        else { return [:] }

        let managedSpaces = Self.managedSpaceMap(from: displays)
        guard !managedSpaces.isEmpty else { return [:] }

        var result: [CGWindowID: ResolvedWindowSpace] = [:]
        for windowID in windowIDs {
            let identifiers = [NSNumber(value: windowID)] as CFArray
            guard let spacesArray = copySpacesForWindows(
                connection,
                0x7,
                identifiers
            )?.takeRetainedValue(),
            let spaceIDs = spacesArray as? [NSNumber],
            let match = spaceIDs.lazy.compactMap({ identifier -> ResolvedWindowSpace? in
                let value = identifier.uint64Value
                guard let managed = managedSpaces[value] else { return nil }
                return ResolvedWindowSpace(
                    identifier: value,
                    number: managed.number,
                    isFullScreen: managed.isFullScreen
                )
            }).first
            else { continue }
            result[windowID] = match
        }
        return result
    }

    static func managedSpaceMap(from displays: [[String: Any]]) -> [UInt64: ManagedSpace] {
        var result: [UInt64: ManagedSpace] = [:]
        var nextNumber = 1

        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                guard let identifier = space["id64"] as? NSNumber else { continue }
                let type = (space["type"] as? NSNumber)?.intValue ?? 0
                let number: Int?
                if type == 0 {
                    number = nextNumber
                    nextNumber += 1
                } else {
                    // Spaces nativos de Tela Cheia são nomeados pelo app no
                    // Mission Control e não consomem a numeração dos Desktops.
                    number = nil
                }
                result[identifier.uint64Value] = ManagedSpace(
                    number: number,
                    isFullScreen: type != 0
                )
            }
        }
        return result
    }
}
