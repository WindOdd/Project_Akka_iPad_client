import SwiftUI

struct ContentView: View {
    // 建立 ViewModel
    @StateObject private var viewModel = MainViewModel()
    
    // 暫時將 IP 狀態放在這裡 (手動輸入)
    @State private var serverIP: String = "192.168.50.10" // 預設值，請改成你的
    @State private var inputMessage: String = ""
    
    var body: some View {
        VStack {
            // MARK: - 1. 頂部連線測試區 (最簡單的 Debug 方式)
            HStack {
                TextField("輸入 Server IP", text: $serverIP)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .keyboardType(.numbersAndPunctuation)
                
                Button("連線") {
                    // 呼叫你的 ViewModel 連線功能
                    // 注意：如果你的函式名稱不一樣，請在這裡修改
                    // 例如: viewModel.connect(host: serverIP)
                    print("嘗試連線到: \(serverIP)")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(Color.gray.opacity(0.1))

            // MARK: - 2. 聊天顯示區
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // 這裡先用 Text 顯示，避免 ChatBubble 參數錯誤
                    // 等編譯成功後，再把 ChatBubble 加回來
                    Text("系統: 歡迎使用桌遊語音助理")
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                    
                    // 如果你的 ViewModel 有 messages 陣列，請解開下面這行註解：
                    // ForEach(viewModel.messages) { msg in ChatBubble(message: msg) }
                }
                .padding()
            }
            
            Spacer()

            // MARK: - 3. 底部操作區
            HStack {
                TextField("輸入訊息...", text: $inputMessage)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button(action: {
                    // 發送訊息邏輯
                    print("發送: \(inputMessage)")
                    inputMessage = ""
                }) {
                    Image(systemName: "paperplane.fill")
                }
            }
            .padding()
        }
        .onAppear {
            // 可以在這裡印出 log 確認 ViewModel 是否活著
            print("ContentView Loaded")
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
