import AppKit
import CoreGraphics

let applications = Dictionary(
    uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
        ($0.processIdentifier, $0)
    }
)

guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}

for info in windowList {
    guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
          let application = applications[ownerPIDNumber.int32Value],
          let layer = info[kCGWindowLayer as String] as? NSNumber,
          let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
    else { continue }

    let title = info[kCGWindowName as String] as? String ?? ""
    let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    let bundlePath = application.bundleURL?.path ?? ""
    let context = WindowEligibilityContext(
        bundleIdentifier: application.bundleIdentifier ?? "",
        activationPolicy: application.activationPolicy,
        title: title,
        bounds: bounds,
        layer: layer.intValue,
        alpha: alpha,
        isOnScreen: isOnScreen,
        isHelperProcess: bundlePath.contains(".app/Contents/") || bundlePath.hasSuffix(".xpc")
    )
    let allowed = WindowEligibilityPolicy.allows(context, includeUtilityWindows: true)

    guard bounds.width >= 40, bounds.height >= 30 else { continue }
    let result = allowed ? "INCLUI" : "EXCLUI"
    print(
        "\(result)\t\(application.localizedName ?? "-")\t"
            + "\(application.bundleIdentifier ?? "-")\t"
            + "on=\(isOnScreen)\t\(Int(bounds.width))x\(Int(bounds.height))\t\(title)"
    )
}
