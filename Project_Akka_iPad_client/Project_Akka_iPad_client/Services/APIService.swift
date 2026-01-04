import Foundation
import Combine // 🔥 確保支援 Combine 框架

class APIService: ObservableObject {
    
    // MARK: - API 1: 取得支援遊戲列表 (Get Supported Games)

    // 檔案：Services/APIService.swift
    // 👇 [新增] 1. 定義常駐的 session
        private let session: URLSession
    // 👇 [新增] 2. 在 init 初始化
        init() {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5
            self.session = URLSession(configuration: config)
        }
        func fetchGames(ip: String) async throws -> [GameInfo] {
                // 🔥 [Debug] 印出正在嘗試的完整網址，方便檢查 IP   是否正確
                let urlString = "http://\(ip):8000/api/games"
                print("📡 嘗試連線: \(urlString)")
            
                // 檢查 URL 是否建立成功
                guard let url = URL(string: urlString) else {
                    print("❌ [API 1 Error] URL 建立失敗！請檢查 IP 是否包含空白或非法字元: [\(ip)]")
                    throw URLError(.badURL)
                }
                
                do {
                    // 設定短一點的 Timeout (5秒)，不要讓介面卡住太久
                    //let config = URLSessionConfiguration.default
                    //config.timeoutIntervalForRequest = 5
                    //let session = URLSession(configuration: config)
                    
                    let (data, response) = try await session.data(from: url)
                    
                    if let httpResponse = response as? HTTPURLResponse {
                        print("📡 [API 1 Response Code]: \(httpResponse.statusCode)")
                    }
                    
                    let decodedResponse = try JSONDecoder().decode(GameListResponse.self, from: data)
                    return decodedResponse.games
                } catch {
                    print("❌ [API 1 Failed]: \(error.localizedDescription)")
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
        if let rawJSON = String(data: data, encoding: .utf8) {
                    print("📦 [API 2 Raw Keywords]: \(rawJSON)")
                }
                
                // 解析並回傳關鍵字字串陣列
        let decodedResponse = try JSONDecoder().decode(STTKeywordsResponse.self, from: data)
        return decodedResponse.keywords
    }
    
    // MARK: - API 3: 對話請求 (Chat Request)

    // MARK: - API 3: 對話請求 (Chat Request)

        func sendChat(ip: String, request: ChatRequest) async throws -> ChatResponse {
            guard let url = URL(string: "http://\(ip):8000/api/chat") else {
                throw URLError(.badURL)
            }
            
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            // 將 request 編碼發送
            urlRequest.httpBody = try JSONEncoder().encode(request)
            
            // 取得回應
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            
            // 🔥 [Debug 1] 印出 HTTP 狀態碼
            if let httpResponse = response as? HTTPURLResponse {
                print("📡 [Chat API Status]: \(httpResponse.statusCode)")
            }
            
            // 🔥 [Debug 2] 印出 Server 回傳的原始 JSON 字串 (關鍵步驟)
            if let rawString = String(data: data, encoding: .utf8) {
                print("📦 [Server Raw Response]: \(rawString)")
            }
            
            // 🔥 [Debug 3] 捕捉並印出具體的解析錯誤
            do {
                return try JSONDecoder().decode(ChatResponse.self, from: data)
            } catch {
                print("❌ [JSON Decoding Error]: \(error)")
                // 常見錯誤提示：
                // keyNotFound: Server 少給了某個欄位
                // typeMismatch: Server 給了字串但 App 預期是數字
                throw error // 拋出錯誤讓 ViewModel 處理
            }
        }
}
