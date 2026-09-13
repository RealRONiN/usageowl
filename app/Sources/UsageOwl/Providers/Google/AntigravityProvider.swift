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

                let valid =
                models.compactMap {
                    remaining($0).map {
                        ($0, $0, $0)
                    }
                }

                guard let lowest =
                        valid.min(by: {
                            $0.0 < $1.0
                        })
                else {
                    return nil
                }

                let reset =
                models
                    .compactMap {
                        $0["resetTime"] as? String
                    }
                    .first

                return UsageWindow(
                    label: label,
                    usedPercent:
                        (1 - lowest.0) * 100,
                    resetDate:
                        Format.date(
                            from: reset
                        )
                )
            }

            let gemini =
            models.filter {
                (($0["label"] as? String) ?? "")
                    .lowercased()
                    .contains("gemini")
            }

            let other =
            models.filter {
                let label =
                (($0["label"] as? String) ?? "")
                    .lowercased()

                return
                    label.contains("claude")
                    ||
                    label.contains("gpt")
            }

            var windows:[UsageWindow] = []

            if let w = makePool(
                label: "Gemini Session",
                models: gemini
            ) {
                windows.append(w)
            }

            if let w = makePool(
                label: "Gemini Weekly",
                models: gemini
            ) {
                windows.append(w)
            }

            if let w = makePool(
                label: "Claude + GPT Session",
                models: other
            ) {
                windows.append(w)
            }

            if let w = makePool(
                label: "Claude + GPT Weekly",
                models: other
            ) {
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
