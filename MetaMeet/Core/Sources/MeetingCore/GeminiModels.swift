import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum GeminiModels {
    public static let defaultModel = "gemini-3.6-flash"
    public static func migrated(_ saved: String?) -> String {
        guard let saved, !saved.isEmpty, !saved.hasPrefix("gemini-2.5-flash"), !saved.hasPrefix("gemini-2.0-") else { return defaultModel }
        return saved
    }
    public static func candidates(from data: Data) throws -> (models: [String], nextPage: String?) {
        struct Model: Decodable { let name: String; let supportedGenerationMethods: [String]? }
        struct Page: Decodable { let models: [Model]?; let nextPageToken: String? }
        let page = try JSONDecoder().decode(Page.self, from: data)
        let names = (page.models ?? []).filter { $0.supportedGenerationMethods?.contains("generateContent") == true }.map { $0.name.replacingOccurrences(of: "models/", with: "") }.filter {
            $0.range(of: #"^gemini-(?:[0-9]+\.[0-9]+|[0-9]+)-flash(?:-lite)?(?:-preview)?$"#, options: .regularExpression) != nil && !$0.hasPrefix("gemini-2.")
        }
        return (names, page.nextPageToken)
    }
    public static func list(key: String) async throws -> [String] {
        var names: [String] = []; var token: String?; var seen = Set<String>()
        repeat {
            var url = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            url.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
            if let token { url.queryItems?.append(URLQueryItem(name: "pageToken", value: token)) }
            var request = URLRequest(url: url.url!); request.timeoutInterval = 30
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let data = try await GeminiClient.send(request, key: key)
            let page = try candidates(from: data); names += page.models; token = page.nextPage
            if let token, !seen.insert(token).inserted { throw GeminiFailure("모델 목록의 페이지 응답이 반복됐습니다.") }
        } while token != nil
        return Array(Set(names)).sorted { a, b in
            if a == defaultModel { return true }; if b == defaultModel { return false }
            return a.localizedStandardCompare(b) == .orderedDescending
        }
    }
}
