import Foundation

struct DriverInstaller {
    static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/MicEQ.driver"

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.installedDriverPath)
    }

    func uninstall(progress: @escaping @Sendable (_ fraction: Double, _ phase: String) -> Void) async throws {
        progress(0.15, "Requesting admin permission…")

        let destPath = Self.installedDriverPath
        let command = [
            "set -e",
            "rm -rf \(shellQuote(destPath))",
            // Restart CoreAudio so it unloads the HAL plug-in.
            "killall -9 coreaudiod || true",
        ].joined(separator: "; ")

        let appleScript = "do shell script \"\(escapeAppleScriptString(command))\" with administrator privileges"

        try await runProcess(
            launchPath: "/usr/bin/osascript",
            arguments: ["-e", appleScript]
        )

        progress(0.95, "Finalizing…")
    }

    func install(progress: @escaping @Sendable (_ fraction: Double, _ phase: String) -> Void) async throws {
        progress(0.05, "Locating bundled driver…")

        guard let sourceURL = Bundle.main.url(forResource: "MicEQ", withExtension: "driver") else {
            throw InstallError.missingBundledDriver
        }

        let destPath = Self.installedDriverPath

        progress(0.15, "Requesting admin permission…")

        let command = [
            "set -e",
            "rm -rf \(shellQuote(destPath))",
            "cp -R \(shellQuote(sourceURL.path)) \(shellQuote(destPath))",
            "xattr -dr com.apple.quarantine \(shellQuote(destPath)) || true",
            "chown -R root:wheel \(shellQuote(destPath)) || true",
            "chmod -R go-w \(shellQuote(destPath)) || true",
            // Restart CoreAudio so it loads the new HAL plug-in.
            "killall -9 coreaudiod || true",
        ].joined(separator: "; ")

        let appleScript = "do shell script \"\(escapeAppleScriptString(command))\" with administrator privileges"

        try await runProcess(
            launchPath: "/usr/bin/osascript",
            arguments: ["-e", appleScript]
        )

        progress(0.95, "Finalizing…")
    }

    private func shellQuote(_ s: String) -> String {
        // Wrap in single quotes and escape embedded single quotes safely.
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeAppleScriptString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runProcess(launchPath: String, arguments: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments

        let stderr = Pipe()
        let stdout = Pipe()
        proc.standardError = stderr
        proc.standardOutput = stdout

        try proc.run()

        return try await withCheckedThrowingContinuation { cont in
            proc.terminationHandler = { p in
                let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()

                let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: InstallError.processFailed(code: Int(p.terminationStatus), stdout: out, stderr: err))
                }
            }
        }
    }

    enum InstallError: LocalizedError {
        case missingBundledDriver
        case processFailed(code: Int, stdout: String, stderr: String)

        var errorDescription: String? {
            switch self {
            case .missingBundledDriver:
                return "Bundled driver not found in app resources (MicEQ.driver)."
            case .processFailed(let code, let stdout, let stderr):
                var msg = "Driver install failed (osascript exit \(code))."
                if !stderr.isEmpty { msg += "\n\(stderr)" }
                if !stdout.isEmpty { msg += "\n\(stdout)" }
                return msg
            }
        }
    }
}
