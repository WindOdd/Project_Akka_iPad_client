import SwiftUI

// 昨天使用的基礎結構，移除所有 intent 欄位
struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let text: String
    let isUser: Bool
    let source: String?
}

struct ChatBubble: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if message.isUser { Spacer() }
            else {
                Image(systemName: "cpu")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundColor(.orange)
                    .padding(.bottom, 20)
            }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .foregroundColor(.white)
                    .background(message.isUser ? Color.blue : Color(UIColor.systemGray2))
                    .cornerRadius(16)
                
                if !message.isUser, let src = message.source {
                    Text(src).font(.caption2).foregroundColor(.gray).padding(.leading, 4)
                }
            }
            if !message.isUser { Spacer() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
