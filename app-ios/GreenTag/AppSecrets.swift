import Foundation

enum AppSecrets {
    static var roboflowAPIKey: String {
        string(for: "ROBOFLOW_API_KEY")
    }

    private static func string(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return ""
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("$(") ? "" : trimmed
    }
}
