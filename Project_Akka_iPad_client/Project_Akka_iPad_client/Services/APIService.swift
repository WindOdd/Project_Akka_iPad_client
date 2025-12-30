import Foundation
import Combine

class APIService: ObservableObject {
    
    // [Spec v9.8] POST /api/chat
    func sendChat(serverIP: String, text: String, game: String, history: [ChatMessage]) async throws -> ChatResponse {
        
        guard let url = URL(string: "http://\(serverIP):8000/api/chat") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15.0
        
        // 1. 轉換歷史紀錄 (Client History -> API HistoryItem)
        // [Spec v9.8] 必須包含 intent，讓 Server 知道上一句是在聊規則還是廁所
        let apiHistory = history.map { msg in
            HistoryItem(
                role: msg.isUser ? "user" : "assistant",
                content: msg.text,
                intent: msg.intent // 傳遞 intent
            )
        }
        
        // 2. 組裝 Payload (符合 v9.8 巢狀結構)
        let payload = ChatRequest(
            table_id: "T01",
            session_id: UUID().uuidString,
            game_context: GameContext(game_name: game), // [v9.8] 巢狀
            user_input: text,                           // [v9.8] 欄位更名
            history: apiHistory
        )
        
        request.httpBody = try JSONEncoder().encode(payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }
}
