import AppKit
import CoreGraphics
import Foundation

struct Options {
    var bundleFilter = ""
    var includeUtilityWindows = true
    var showTitles = false
    var eligibleOnly = false
    var selfTest = false
}

struct ProbeRow {
    let applicationName: String
    let bundleIdentifier: String
    let ownerPID: pid_t
    let windowID: CGWindowID
    let activationPolicy: NSApplication.ActivationPolicy
    let isHelperProcess: Bool
    let isOnScreen: Bool
    let layer: Int
    let alpha: CGFloat
    let bounds: CGRect
    let title: String
    let decision: WindowEligibilityDecision
}

func usage() {
    print("""
    Uso: taber-window-check [opções]

      --bundle TEXTO       mostra apenas nome/bundle que contenha TEXTO
      --eligible-only      omite superfícies excluídas
      --exclude-utilities  avalia com janelas auxiliares desativadas
      --show-titles        inclui títulos (ocultos por padrão por privacidade)
      --self-test          valida fixtures da política sem consultar janelas
      --help               mostra esta ajuda

    Exemplo para League: taber-window-check --bundle league
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("erro: \(message)\n".utf8))
    exit(2)
}

func sanitized(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

func policyName(_ policy: NSApplication.ActivationPolicy) -> String {
    switch policy {
    case .regular: return "regular"
    case .accessory: return "accessory"
    case .prohibited: return "prohibited"
    @unknown default: return "unknown"
    }
}

func activationFallback(for row: ProbeRow) -> String {
    guard row.decision.isEligible else { return "none" }
    switch row.decision.reason {
    case .customSurface, .nestedRenderer:
        return "application-if-AX-unavailable"
    case .standardWindow, .dialog, .utility:
        return "accessibility-window"
    case .systemShell, .noUserSurface, .utilityDisabled, .implausibleGeometry:
        return "none"
    }
}

var options = Options()
let arguments = Array(CommandLine.arguments.dropFirst())
var argumentIndex = 0
while argumentIndex < arguments.count {
    switch arguments[argumentIndex] {
    case "--bundle":
        guard argumentIndex + 1 < arguments.count else { fail("--bundle requer um texto") }
        options.bundleFilter = arguments[argumentIndex + 1]
        argumentIndex += 2
    case "--eligible-only":
        options.eligibleOnly = true
        argumentIndex += 1
    case "--exclude-utilities":
        options.includeUtilityWindows = false
        argumentIndex += 1
    case "--show-titles":
        options.showTitles = true
        argumentIndex += 1
    case "--self-test":
        options.selfTest = true
        argumentIndex += 1
    case "--help", "-h":
        usage()
        exit(0)
    default:
        fail("opção desconhecida: \(arguments[argumentIndex])")
    }
}

if options.selfTest {
    let fixtures: [(String, WindowEligibilityContext, Bool, WindowEligibilityReason)] = [
        (
            "league-like nested renderer",
            .init(bundleIdentifier: "com.riotgames.leagueoflegends",
                  activationPolicy: .accessory, title: "", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
                  layer: 0, alpha: 1, isOnScreen: true, isHelperProcess: true, evidence: .windowServer),
            true,
            .nestedRenderer
        ),
        (
            "system shell",
            .init(bundleIdentifier: "com.apple.controlcenter",
                  activationPolicy: .regular, title: "Control Center", bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
                  layer: 0, alpha: 1, isOnScreen: true, isHelperProcess: false, evidence: .both),
            false,
            .systemShell
        ),
        (
            "technical geometry",
            .init(bundleIdentifier: "example.helper",
                  activationPolicy: .prohibited, title: "", bounds: CGRect(x: 0, y: 0, width: 12, height: 12),
                  layer: 0, alpha: 1, isOnScreen: true, isHelperProcess: true, evidence: .windowServer),
            false,
            .implausibleGeometry
        ),
        (
            "AX dialog",
            .init(bundleIdentifier: "example.application",
                  activationPolicy: .regular, title: "Dialog", bounds: CGRect(x: 0, y: 0, width: 480, height: 320),
                  layer: 0, alpha: 1, isOnScreen: true, isHelperProcess: false,
                  evidence: .accessibility, accessibilitySubrole: kAXDialogSubrole as String),
            true,
            .dialog
        )
    ]
    var failures = 0
    for (name, context, expectedEligibility, expectedReason) in fixtures {
        let decision = WindowEligibilityPolicy.evaluate(context, includeUtilityWindows: true)
        let passed = decision.isEligible == expectedEligibility && decision.reason == expectedReason
        print("\(passed ? "PASS" : "FAIL")\t\(name)\treason=\(decision.reason.rawValue)")
        if !passed { failures += 1 }
    }
    print("SUMMARY\tfixtures=\(fixtures.count)\tfailures=\(failures)")
    exit(failures == 0 ? 0 : 1)
}

let applications = Dictionary(
    uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
        ($0.processIdentifier, $0)
    }
)

guard let windowList = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else {
    fail("WindowServer não forneceu a lista de janelas")
}

let normalizedFilter = options.bundleFilter.folding(
    options: [.caseInsensitive, .diacriticInsensitive],
    locale: .current
)
var rows: [ProbeRow] = []

for info in windowList {
    guard let ownerPIDNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
          let application = applications[ownerPIDNumber.int32Value],
          let windowIDNumber = info[kCGWindowNumber as String] as? NSNumber,
          let layer = info[kCGWindowLayer as String] as? NSNumber,
          let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsDictionary)
    else { continue }

    let applicationName = application.localizedName ?? "-"
    let bundleIdentifier = application.bundleIdentifier ?? "-"
    if !normalizedFilter.isEmpty {
        let searchable = "\(applicationName) \(bundleIdentifier)".folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        guard searchable.contains(normalizedFilter) else { continue }
    }

    let title = info[kCGWindowName as String] as? String ?? ""
    let isOnScreen = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
    let bundlePath = application.bundleURL?.path ?? ""
    let isHelperProcess = bundlePath.contains(".app/Contents/") || bundlePath.hasSuffix(".xpc")
    let context = WindowEligibilityContext(
        bundleIdentifier: application.bundleIdentifier ?? "",
        activationPolicy: application.activationPolicy,
        title: title,
        bounds: bounds,
        layer: layer.intValue,
        alpha: alpha,
        isOnScreen: isOnScreen,
        isHelperProcess: isHelperProcess,
        evidence: .windowServer
    )
    let decision = WindowEligibilityPolicy.evaluate(
        context,
        includeUtilityWindows: options.includeUtilityWindows
    )
    guard decision.isEligible || !options.eligibleOnly else { continue }

    rows.append(ProbeRow(
        applicationName: applicationName,
        bundleIdentifier: bundleIdentifier,
        ownerPID: application.processIdentifier,
        windowID: CGWindowID(windowIDNumber.uint32Value),
        activationPolicy: application.activationPolicy,
        isHelperProcess: isHelperProcess,
        isOnScreen: isOnScreen,
        layer: layer.intValue,
        alpha: CGFloat(alpha),
        bounds: bounds,
        title: title,
        decision: decision
    ))
}

rows.sort {
    let nameOrder = $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
    if $0.ownerPID != $1.ownerPID { return $0.ownerPID < $1.ownerPID }
    return $0.windowID < $1.windowID
}

print("Taber Window Eligibility Check")
print("source=WindowServer includeUtilities=\(options.includeUtilityWindows) titles=\(options.showTitles ? "visible" : "redacted") filter=\(options.bundleFilter.isEmpty ? "none" : sanitized(options.bundleFilter))")
print("Nota: activationFallback é uma previsão da sonda CG; confirme a estratégia efetiva no log de ativação do Taber.")

for row in rows {
    let result = row.decision.isEligible ? "INCLUI" : "EXCLUI"
    var fields = [
        result,
        "reason=\(row.decision.reason.rawValue)",
        "app=\(sanitized(row.applicationName))",
        "bundle=\(sanitized(row.bundleIdentifier))",
        "pid=\(row.ownerPID)",
        "window=\(row.windowID)",
        "policy=\(policyName(row.activationPolicy))",
        "helper=\(row.isHelperProcess)",
        "onScreen=\(row.isOnScreen)",
        "layer=\(row.layer)",
        "alpha=\(String(format: "%.2f", Double(row.alpha)))",
        "bounds=\(Int(row.bounds.origin.x)),\(Int(row.bounds.origin.y)),\(Int(row.bounds.width))x\(Int(row.bounds.height))",
        "activationFallback=\(activationFallback(for: row))"
    ]
    if options.showTitles {
        fields.append("title=\(sanitized(row.title))")
    } else {
        fields.append("title=\(row.title.isEmpty ? "empty" : "redacted")")
    }
    print(fields.joined(separator: "\t"))
}

let eligibleCount = rows.filter(\.decision.isEligible).count
let reasonSummary = Dictionary(grouping: rows, by: { $0.decision.reason })
    .map { "\($0.key.rawValue):\($0.value.count)" }
    .sorted()
    .joined(separator: ",")
print("SUMMARY\ttotal=\(rows.count)\teligible=\(eligibleCount)\texcluded=\(rows.count - eligibleCount)\treasons=\(reasonSummary.isEmpty ? "none" : reasonSummary)")
