import Foundation
import SwiftUI

struct AntigravityProvider: AIProvider {

    let id = "antigravity"
    let name = "Antigravity"
    let brandColor = Color.blue

    let setupHint =
    "Sign in to Antigravity CLI or Antigravity IDE"

    func isAvailable() -> Bool {
        FileManager.default.fileExists(
            atPath: "/Users/aniket/bin/antigravity-usage-json"
        )
    }


    func fetchUsage() async -> UsageSnapshot {

        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(
            fileURLWithPath:
            "/Users/aniket/bin/antigravity-usage-json"
        )

        process.standardOutput = pipe

        do {

            try process.run()

            let data =
            pipe.fileHandleForReading.readDataToEndOfFile()

            let root =
            try JSONSerialization.jsonObject(
                with: data
            ) as? [String:Any]

            guard let models =
                    root?["models"] as? [[String:Any]]
            else {
                return errorSnapshot(
                    "Antigravity: invalid models payload"
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
