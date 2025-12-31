import Foundation
import Combine

struct ChatResponse: Codable {
    let response: String
    let source: String
}

class APIService: ObservableObject {
    func sendChat(serverIP: String, text: String) async throws -> ChatResponse {
        guard let url = URL(string: "http://\(serverIP):8000/api/chat") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 昨天能跑的簡單 JSON 格式
        let body: [String: String] = ["text": text]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }
}
