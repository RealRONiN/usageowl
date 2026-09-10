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
                with:data
            ) as? [String:Any]

            var windows:[UsageWindow] = []

            
if let models =
    root?["models"] as? [[String:Any]]
{

    func addPool(
        _ label: String,
        _ pool: [[String:Any]]
    ) {

        guard let first = pool.first else {
            return
        }

        guard let remaining =
            first["remainingPercentage"] as? Double
        else {
            return
        }

        windows.append(
            UsageWindow(
                label: label,
                usedPercent: (1 - remaining) * 100,
                resetDate:
                    Format.date(
                        from:
                        first["resetTime"] as? String
                    )
            )
        )
    }


    let gemini =
    models.filter {
        (($0["label"] as? String) ?? "")
            .lowercased()
            .contains("gemini")
    }


    let nonGemini =
    models.filter {
        let label =
        (($0["label"] as? String) ?? "")
            .lowercased()

        return
            label.contains("claude")
            ||
            label.contains("gpt")
    }


    addPool(
        "Gemini Session",
        gemini
    )


    addPool(
        "Gemini Weekly",
        gemini
    )


    addPool(
        "Claude + GPT Session",
        nonGemini
    )


    addPool(
        "Claude + GPT Weekly",
        nonGemini
    )
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
