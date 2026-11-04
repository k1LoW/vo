import ArgumentParser
import Foundation
import FoundationModels

struct DoctorReport: Sendable {
    let osVersion: String
    let osCompatible: Bool
    let hostname: String
    let speechLocales: [SpeechLocaleInfo]
    let translationLanguages: [String]
    let inputDevices: [AudioDeviceInfo]
    let foundationModelsAvailable: Bool
    let foundationModelsReason: String?
}

/// Print a full environment report: OS, speech models, translation languages, audio devices.
func runDoctor(json: Bool) async throws {
    let report = await gatherDoctorReport()
    if json {
        try printDoctorJSON(report)
    } else {
        printDoctorText(report)
        if !report.osCompatible {
            throw ExitCode.failure
        }
    }
}

// MARK: - Gather

private func gatherDoctorReport() async -> DoctorReport {
    let osv = ProcessInfo.processInfo.operatingSystemVersion
    let osStr = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
    let osCompatible = osv.majorVersion >= 26

    let speech = await collectSpeechLocales()
    let translation = await collectTranslationLanguages()
    let devices = (try? collectInputDevices()) ?? []
    let fmStatus = Summarizer.availabilityStatus()

    return DoctorReport(
        osVersion: osStr,
        osCompatible: osCompatible,
        hostname: ProcessInfo.processInfo.hostName,
        speechLocales: speech,
        translationLanguages: translation,
        inputDevices: devices,
        foundationModelsAvailable: fmStatus.available,
        foundationModelsReason: fmStatus.reason
    )
}

// MARK: - Text output

private func printDoctorText(_ r: DoctorReport) {
    section("System")
    if r.osCompatible {
        ok("macOS \(r.osVersion) (≥ 26 required)")
    } else {
        fail("macOS \(r.osVersion) is too old; vo requires macOS 26+.")
    }
    ok("Hostname: \(r.hostname)")

    section("Speech (transcription)")
    let installedCount = r.speechLocales.filter { $0.installed }.count
    ok("\(installedCount) installed / \(r.speechLocales.count) supported")
    for loc in r.speechLocales {
        let mark = loc.installed
            ? "\u{001B}[32m✓\u{001B}[0m installed"
            : "  available"
        print("    \(mark)  \(loc.identifier)")
    }

    section("Translation")
    ok("\(r.translationLanguages.count) languages available on this device")
    print("    \(r.translationLanguages.joined(separator: ", "))")

    section("Foundation Models (Apple Intelligence)")
    if r.foundationModelsAvailable {
        ok("Foundation Models available on this device (ready for --summary)")
    } else {
        warn("Foundation Models unavailable: \(r.foundationModelsReason ?? "Unknown reason")")
    }

    section("Input devices")
    if r.inputDevices.isEmpty {
        warn("No input devices found.")
    } else {
        let nameWidth = max(r.inputDevices.map { $0.name.count }.max() ?? 0, 4)
        for d in r.inputDevices {
            let marker = d.isDefault ? "\u{001B}[32m✓\u{001B}[0m default" : "          "
            let name = d.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            print("    \(marker)  \(name)  channels=\(d.channels)  uid=\(d.uid)")
        }
    }

    section("TCC permissions (best effort)")
    info("vo cannot directly query TCC. On first run it will prompt for:")
    info("  - Microphone")
    info("  - Speech Recognition")
    info("  - Audio Recording (Core Audio process tap for the speaker channel)")
    info("If launched from Terminal, those grants attach to Terminal.app.")

    section("Summary")
    if r.osCompatible {
        ok("Ready to run `vo`.")
    } else {
        fail("OS not compatible.")
    }
}

// MARK: - JSON output

private func printDoctorJSON(_ r: DoctorReport) throws {
    var foundationModelsPayload: [String: Any] = [
        "available": r.foundationModelsAvailable
    ]
    if let reason = r.foundationModelsReason {
        foundationModelsPayload["reason"] = reason
    }

    let payload: [String: Any] = [
        "system": [
            "os": r.osVersion,
            "hostname": r.hostname,
            "compatible": r.osCompatible
        ] as [String: Any],
        "speech": [
            "supportedCount": r.speechLocales.count,
            "installedCount": r.speechLocales.filter { $0.installed }.count,
            "locales": r.speechLocales.map { loc -> [String: Any] in
                ["locale": loc.identifier, "installed": loc.installed]
            }
        ] as [String: Any],
        "translation": [
            "languages": r.translationLanguages
        ] as [String: Any],
        "foundationModels": foundationModelsPayload,
        "devices": r.inputDevices.map { d -> [String: Any] in
            [
                "id": Int(d.id),
                "uid": d.uid,
                "name": d.name,
                "channels": d.channels,
                "default": d.isDefault
            ]
        }
    ]
    let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
    )
    if let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

// MARK: - Formatting helpers

private func section(_ title: String) { print("\n\u{001B}[1m\(title)\u{001B}[0m") }
private func ok(_ s: String)   { print("  \u{001B}[32m✓\u{001B}[0m \(s)") }
private func warn(_ s: String) { print("  \u{001B}[33m!\u{001B}[0m \(s)") }
private func fail(_ s: String) { print("  \u{001B}[31m✗\u{001B}[0m \(s)") }
private func info(_ s: String) { print("    \(s)") }
