import Foundation

/// Fetches OpenRouter credit balance from the public `/credits` endpoint.
struct OpenRouterCredits: Equatable, Decodable {
    let totalCredits: Double
    let totalUsage: Double

    enum CodingKeys: String, CodingKey {
        case data
    }
    enum DataKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }

    init(from decoder: Decoder) throws {
        let dataContainer = try decoder.container(keyedBy: CodingKeys.self)
            .nestedContainer(keyedBy: DataKeys.self, forKey: .data)
        totalCredits = try dataContainer.decode(Double.self, forKey: .totalCredits)
        totalUsage = try dataContainer.decode(Double.self, forKey: .totalUsage)
    }

    init(totalCredits: Double, totalUsage: Double) {
        self.totalCredits = totalCredits
        self.totalUsage = totalUsage
    }

    var remaining: Double { max(0, totalCredits - totalUsage) }
}

@MainActor
final class OpenRouterService: ObservableObject {
    static let shared = OpenRouterService()
    static let account = "openrouter-api-key"

    @Published private(set) var credits: OpenRouterCredits?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var error: String?

    private let session: URLSession
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/credits")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    var hasApiKey: Bool {
        currentApiKey?.isEmpty == false
    }

    /// Returns the Keychain key if set, otherwise falls back to the
    /// `OPENROUTER_API_KEY` environment variable.
    var currentApiKey: String? {
        if let key = KeychainStore.get(account: Self.account), !key.isEmpty {
            return key
        }
        if let envKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !envKey.isEmpty {
            return envKey
        }
        return nil
    }

    func refresh() async {
        guard let key = currentApiKey else {
            self.error = "No API key set."
            return
        }

        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                self.error = "OpenRouter request failed."
                return
            }
            let credits = try JSONDecoder().decode(OpenRouterCredits.self, from: data)
            self.credits = credits
            self.lastRefresh = Date()
            self.error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
