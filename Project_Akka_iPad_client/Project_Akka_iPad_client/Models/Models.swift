import Foundation
import Combine

// MARK: - API 1: 取得支援遊戲列表 (Get Supported Games)

struct GameListResponse: Codable {
    let games: [GameInfo]
}

struct GameInfo: Codable, Identifiable {
    let id: String           // 系統內部 ID
    let name: String         // 顯示名稱
    let description: String  // 遊戲描述
    let enable_stt_injection: Bool
}

// MARK: - API 2: 取得 STT 修正關鍵字 (Get STT Keywords)

struct STTKeywordsResponse: Codable {
    let id: String?
    let correction_enabled: Bool?
    let keywords: [String]
}

// MARK: - API 3: 對話請求 (Chat Request)

struct ChatRequest: Codable {
    let table_id: String
    let session_id: String
    let game_context: GameContext
    let user_input: String
    let history: [ChatMessage]
}

struct GameContext: Codable {
    let game_name: String
}

struct ChatMessage: Codable, Identifiable {
    var id = UUID()
    let role: String
    let content: String
    let intent: String
    
    enum CodingKeys: String, CodingKey {
        case role, content, intent
    }
}

// MARK: - API 3: 對話回應 (Chat Response)

struct ChatResponse: Codable {
    let response: String    // AI 的回答文字
    let intent: String      // Server 判斷的意圖
    let source: String      // 回答來源
    
    // 🔥 [修改] 改為 Optional (?)，因為 Server 這次沒回傳這個欄位
    let latency_ms: Int?
    
    // 🔥 [新增] Log 顯示 Server 有回傳 confidence，我們順便接起來
    let confidence: Double?
}

// MARK: - 通用錯誤結構

struct APIErrorResponse: Codable {
    let error_code: String
    let message: String
}
