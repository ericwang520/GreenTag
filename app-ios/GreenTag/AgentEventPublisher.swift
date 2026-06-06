import Foundation

struct AgentEventPublisher {
    let endpoint: URL

    func publish(_ observation: FieldObservation) async throws -> Int {
        let encoder = JSONEncoder()
        let body = try encoder.encode(observation)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PublishError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw PublishError.httpStatus(httpResponse.statusCode)
        }

        return httpResponse.statusCode
    }

    enum PublishError: Error {
        case invalidResponse
        case httpStatus(Int)
    }
}
