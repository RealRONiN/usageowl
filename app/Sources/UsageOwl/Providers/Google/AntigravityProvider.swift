import Foundation
import SwiftUI

struct AntigravityProvider: AIProvider {

    let id = "antigravity"
    let name = "Antigravity"
    let brandColor = Color.blue

    let setupHint =
    "Sign in to Antigravity CLI or Antigravity IDE"

    func isAvailable() -> Bool {

        let home =
            FileManager.default
                .homeDirectoryForCurrentUser
                .path

        let candidates = [
            "\(home)/.local/share/mise/installs/node/lts/bin/antigravity-usage",
            "\(home)/.local/share/mise/installs/node/24.19.0/bin/antigravity-usage",
            "\(home)/.local/share/mise/shims/antigravity-usage",
            "\(home)/.local/bin/antigravity-usage",
            "/usr/local/bin/antigravity-usage",
            "/opt/homebrew/bin/antigravity-usage"
        ]

        return candidates.contains {
            FileManager.default.isExecutableFile(
                atPath: $0
            )
        }
    }


    func fetchUsage() async -> UsageSnapshot {

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        let home =
            FileManager.default
                .homeDirectoryForCurrentUser
                .path

        let cliCandidates = [
            "\(home)/.local/share/mise/installs/node/lts/bin/antigravity-usage",
            "\(home)/.local/share/mise/installs/node/24.19.0/bin/antigravity-usage",
            "\(home)/.local/share/mise/shims/antigravity-usage",
            "\(home)/.local/bin/antigravity-usage",
            "/usr/local/bin/antigravity-usage",
            "/opt/homebrew/bin/antigravity-usage"
        ]

        guard let cliPath =
                cliCandidates.first(
                    where: {
                        FileManager.default
                            .isExecutableFile(
                                atPath: $0
                            )
                    }
                )
        else {
            return errorSnapshot(
                "Antigravity CLI executable not found"
            )
        }

        process.executableURL = URL(
            fileURLWithPath: cliPath
        )

        process.arguments = [
            "quota",
            "--json",
            "--refresh",
            "--all-models",
            "--method",
            "auto"
        ]

        var environment =
            ProcessInfo.processInfo.environment

        let searchPaths = [
            "\(home)/.local/share/mise/installs/node/lts/bin",
            "\(home)/.local/share/mise/installs/node/24.19.0/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.local/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        let inheritedPath =
            environment["PATH"] ?? ""

        environment["PATH"] =
            (searchPaths + [inheritedPath])
                .filter { !$0.isEmpty }
                .joined(separator: ":")

        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr

        do {

            try process.run()

            let data =
                stdout.fileHandleForReading
                    .readDataToEndOfFile()

            let errorData =
                stderr.fileHandleForReading
                    .readDataToEndOfFile()

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {

                let details =
                    String(
                        data: errorData,
                        encoding: .utf8
                    )?
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ) ?? ""

                let suffix =
                    details.isEmpty
                    ? ""
                    : ": \(details)"

                return errorSnapshot(
                    "Antigravity CLI failed "
                    + "(\(process.terminationStatus))"
                    + suffix
                )
            }

            guard !data.isEmpty else {
                return errorSnapshot(
                    "Antigravity CLI returned no data"
                )
            }

            let root =
            try JSONSerialization.jsonObject(
                with: data
            ) as? [String:Any]

            guard let models =
                    root?["models"] as? [[String:Any]]
            else {
                return errorSnapshot(
                    "Antigravity returned an unexpected models payload"
                )
            }

            func remaining(
                _ model: [String:Any]
            ) -> Double? {

                if let value =
                    model["remainingPercentage"] as? Double {
                    return value
                }

                if let value =
                    model["remainingPercentage"] as? NSNumber {
                    return value.doubleValue
                }

                return nil
            }

            func makePool(
                label: String,
                models: [[String:Any]]
            ) -> UsageWindow? {

                let remainingValues =
                models.compactMap {
                    remaining($0)
                }

                let usedPercent =
                remainingValues.isEmpty
                ? 0
                : (1 - (remainingValues.min() ?? 1)) * 100

                let reset =
                models
                    .compactMap {
                        $0["resetTime"] as? String
                    }
                    .first

                return UsageWindow(
                    label: label,
                    usedPercent: usedPercent,
                    resetDate:
                        Format.date(
                            from: reset
                        )
                )
            }

            func pool(
                for model: [String:Any]
            ) -> String {

                let label =
                ((model["label"] as? String) ?? "")
                    .lowercased()

                if label.contains("gemini") {
                    return "Gemini"
                }

                if label.contains("claude")
                    || label.contains("gpt") {
                    return "Claude + GPT"
                }

                return "Other"
            }

            let grouped =
            Dictionary(grouping: models) {
                pool(for: $0)
            }

            var windows:[UsageWindow] = []

            if let w = makePool(
                label: "Gemini",
                models: grouped["Gemini"] ?? []
            ) {
                windows.append(w)
            }

            if let w = makePool(
                label: "Claude + GPT",
                models: grouped["Claude + GPT"] ?? []
            ) {
                windows.append(w)
            }

            if let w = makePool(
                label: "Other",
                models: grouped["Other"] ?? []
            ),
            !((grouped["Other"] ?? []).isEmpty) {
                windows.append(w)
            }

            return snapshot(
                plan: "Google AI Pro",
                windows: windows,
                error:
                    windows.isEmpty
                    ? "No Antigravity quota found"
                    : nil
            )

        } catch {

            return errorSnapshot(
                "Antigravity error: \(error.localizedDescription)"
            )
        }
    }
}
