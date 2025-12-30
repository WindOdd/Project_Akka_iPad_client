//
//  Models.swift
//  Project_Akka_iPad_client
//
//  Created by Sam Lai on 2025/12/31.
//

import Foundation

// [Spec v9.8] 3. 對話請求格式
struct ChatRequest: Codable {
    let table_id: String
    let session_id: String
    let game_context: GameContext // [v9.8] 巢狀結構
    let user_input: String        // [v9.8] 改名 (原為 user_text)
    let history: [HistoryItem]
}

struct GameContext: Codable {
    let game_name: String
}

// [Spec v9.8] 歷史訊息格式 (需包含 intent)
struct HistoryItem: Codable {
    let role: String    // "user" or "assistant"
    let content: String
    let intent: String? // [v9.8] 新增：追蹤上一輪意圖 (RULES, STORE_WIFI...)
}

// [Spec v9.8] Server 回應格式
struct ChatResponse: Codable {
    let response: String
    let intent: String  // [v9.8] Server 判斷的意圖
    let source: String
    let latency_ms: Int?
}

// App 內部使用的 UI 顯示結構
/*struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let text: String
    let isUser: Bool
    let source: String?
    let intent: String? // 用於轉存給下一輪 HistoryItem
}*/
