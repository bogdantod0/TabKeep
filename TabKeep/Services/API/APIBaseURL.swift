import Foundation

enum APIBaseURL {
    static let overrideKey = "api_base_url_override"

    static func resolved() -> URL {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           !override.isEmpty,
           let url = URL(string: override) {
            return url
        }
        #endif
        let value = Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String
            ?? "http://localhost:3000"
        return URL(string: value) ?? URL(string: "http://localhost:3000")!
    }
}
