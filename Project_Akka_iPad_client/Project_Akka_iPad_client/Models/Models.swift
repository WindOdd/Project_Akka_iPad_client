import Foundation
import Combine // 🔥 確保在 ViewModel 中引用這些 Model 時能順利與 Combine 整合

// MARK: - API 1: 取得支援遊戲列表 (Get Supported Games)

struct GameListResponse: Codable {
    let games: [GameInfo]
}

struct GameInfo: Codable, Identifiable {
    let id: String           // 系統內部 ID (如 "Carcassonne")
    let name: String         // 顯示名稱 (如 "卡卡頌")
    let description: String  // 遊戲描述
    let enable_stt_injection: Bool // [重要] 若為 true，代表需呼叫 API 2 取得關鍵字
}

// MARK: - API 2: 取得 STT 修正關鍵字 (Get STT Keywords)


struct STTKeywordsResponse: Codable {
    let id: String
    let correction_enabled: Bool
    let keywords: [String]   // 用於注入 WhisperKit 的 initial_prompt
}

// MARK: - API 3: 對話請求 (Chat Request)

// 注意：必須嚴格遵守巢狀結構與欄位命名

struct ChatRequest: Codable {
    let table_id: String        // 桌號識別 (如 "T01")
    let session_id: String      // 當次對話 Session ID (UUID)
    let game_context: GameContext // [巢狀結構]
    let user_input: String      // [重要] 欄位名必須是 user_input (非 user_text)
    let history: [ChatMessage]  // 建議保留最近 4-8 輪
}

struct GameContext: Codable {
    let game_name: String       // 當前選擇的遊戲 ID
}

// 用於 ChatRequest 中的歷史紀錄結構
struct ChatMessage: Codable, Identifiable {
    var id = UUID()             // 用於 SwiftUI List 識別 (不參與編碼)
    let role: String            // "user" 或 "assistant"
    let content: String         // 對話內容
    let intent: String          // [關鍵] 必須包含上一輪 Server 回傳的意圖標籤 [cite: 458-461]
    
    // 自定義 CodingKeys 以排除 id
    enum CodingKeys: String, CodingKey {
        case role, content, intent
    }
}

// MARK: - API 3: 對話回應 (Chat Response)

struct ChatResponse: Codable {
    let response: String    // AI 的回答文字 (Client 需自行處理 TTS)
    let intent: String      // [重要] Server 判斷的意圖，Client 需存入下一輪 history
    let source: String      // 回答來源 (cloud_rag, local_chat...)
    let latency_ms: Int     // 處理耗時
}

// MARK: - 通用錯誤結構

struct APIErrorResponse: Codable {
    let error_code: String
    let message: String
}
