import SwiftUI

// ⚠️ 注意：已移除檔案內的 struct ChatMessage 定義
// 現在它會自動使用 Models/Models.swift 中的 ChatMessage

struct ChatBubble: View {
    let message: ChatMessage
    
    // 輔助屬性：判斷是否為使用者
    private var isUser: Bool {
        return message.role == "user"
    }
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            //若是使用者，左側留白推到右邊
            if isUser { Spacer() }
            else {
                // 助手頭像 (CPU Icon)
                Image(systemName: "cpu")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.orange)
                    .padding(.bottom, 20)
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // 訊息內容
                Text(message.content)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundColor(.white)
                    .background(isUser ? Color.blue : Color(UIColor.systemGray2))
                    .cornerRadius(16)
                
                // [New] 顯示 Intent 用於驗證 (僅助手顯示)
                // 規格來源:
                if !isUser && !message.intent.isEmpty {
                    Text("Intent: \(message.intent)")
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.leading, 4)
                }
            }
            
            // 若是助手，右側留白推到左邊
            if !isUser { Spacer() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
