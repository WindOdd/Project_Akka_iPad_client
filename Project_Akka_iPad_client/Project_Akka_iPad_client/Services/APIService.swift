import Foundation
import Combine // 🔥 確保支援 Combine 框架

class APIService: ObservableObject {
    
    // MARK: - API 1: 取得支援遊戲列表 (Get Supported Games)

    func fetchGames(ip: String) async throws -> [GameInfo] {
            guard let url = URL(string: "http://\(ip):8000/api/games") else { throw URLError(.badURL) }
            
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                
                // 🔥 [Debug] 印出 Server 回傳的 HTTP 狀態碼與內容
                if let httpResponse = response as? HTTPURLResponse {
                    print("📡 [HTTP Status]: \(httpResponse.statusCode)")
                }
                if let rawJSON = String(data: data, encoding: .utf8) {
                    print("📄 [API 1 Raw Data]: \(rawJSON)")
                }
                
                let decodedResponse = try JSONDecoder().decode(GameListResponse.self, from: data)
                return decodedResponse.games
            } catch {
                print("❌ [API 1 Error]: \(error)") // 這裡會告訴你是不是 JSON 欄位對不上
                throw error
            }
        }
    // MARK: - API 2: 取得 STT 修正關鍵字 (Get STT Keywords)

    func fetchKeywords(ip: String, gameId: String) async throws -> [String] {
        // Path Parameter: game_id [cite: 403]
        guard let url = URL(string: "http://\(ip):8000/api/keywords/\(gameId)") else {
            throw URLError(.badURL)
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        
        // 解析並回傳關鍵字字串陣列
        let decodedResponse = try JSONDecoder().decode(STTKeywordsResponse.self, from: data)
        return decodedResponse.keywords
    }
    
    // MARK: - API 3: 對話請求 (Chat Request)

    func sendChat(ip: String, request: ChatRequest) async throws -> ChatResponse {
        guard let url = URL(string: "http://\(ip):8000/api/chat") else {
            throw URLError(.badURL)
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // 將符合規格的 ChatRequest 結構編碼為 JSON
        urlRequest.httpBody = try JSONEncoder().encode(request)
        
        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        
        // 回傳包含 intent 與 response 的物件
        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }
}
