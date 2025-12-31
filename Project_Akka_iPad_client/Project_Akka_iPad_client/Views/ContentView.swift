import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    
    // IP 暫存
    @AppStorage("manual_server_ip") private var manualIP: String = "192.168.50.10"
    
    // 編輯中的 Table ID
    @State private var editingTableId: String = ""
    
    // 🔥 [新功能] 鎖定模式開關
    // true = 隱藏設定 (給客人用)
    // false = 顯示設定 (給管理員用)
    @State private var isLocked: Bool = true
    
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // MARK: - 1. 頂部狀態/設定區
                VStack(spacing: 12) {
                    
                    // 根據鎖定狀態，決定顯示什麼
                    if isLocked {
                        // 🔒 [鎖定狀態]：只顯示唯讀資訊，客人無法破壞
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(viewModel.udpService.isConnected ? .green : .red)
                            
                            Text(viewModel.udpService.isConnected ? "系統線上" : "離線")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            
                            Spacer()
                            
                            HStack(spacing: 4) {
                                Image(systemName: "tablecells.fill")
                                Text("桌號: \(viewModel.tableId)")
                                    .fontWeight(.bold)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .padding(.horizontal)
                        
                    } else {
                        // 🔓 [解鎖狀態]：顯示完整的設定輸入框 (原本的介面)
                        VStack(spacing: 12) {
                            Text("🔧 管理員設定模式")
                                .font(.caption)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // IP 設定
                            HStack {
                                Image(systemName: "network")
                                    .foregroundColor(.gray)
                                TextField("Server IP", text: $manualIP)
                                    .keyboardType(.numbersAndPunctuation)
                                    .autocapitalization(.none)
                                    .focused($isInputFocused)
                                
                                Button("連線") {
                                    viewModel.udpService.serverIP = manualIP
                                    Task { await viewModel.refreshGames(ip: manualIP) }
                                    isInputFocused = false
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            
                            // Table ID 設定
                            HStack {
                                Image(systemName: "number.square.fill")
                                    .foregroundColor(.orange)
                                TextField("Table ID", text: $editingTableId)
                                    .keyboardType(.asciiCapable)
                                    .autocapitalization(.allCharacters)
                                    .focused($isInputFocused)
                                
                                Button("確認變更") {
                                    viewModel.saveTableId(editingTableId)
                                    isInputFocused = false
                                }
                                .buttonStyle(.bordered)
                            }
                            
                            Divider()
                        }
                    }
                }
                .padding()
                .background(Color(.systemBackground))
                // 給它一點陰影，讓它跟聊天區分開
                .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 5)
                
                // MARK: - 2. 聊天列表區 (不變)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // 系統歡迎詞
                            if viewModel.chatHistory.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "waveform.circle")
                                        .resizable()
                                        .frame(width: 60, height: 60)
                                        .foregroundColor(.blue.opacity(0.3))
                                    Text("阿卡準備好了")
                                        .foregroundColor(.gray)
                                }
                                .padding(.top, 40)
                            }
                            
                            ForEach(viewModel.chatHistory) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.chatHistory.count) { _ in
                        if let lastId = viewModel.chatHistory.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    // 點擊背景收起鍵盤
                    .onTapGesture {
                        isInputFocused = false
                    }
                }
                
                Divider()
                
                // MARK: - 3. 底部操作區 (不變)
                VStack {
                    if let game = viewModel.selectedGame {
                        Text("目前遊戲: \(game.name)")
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                    
                    Button(action: {
                        viewModel.handleMicButtonTap()
                    }) {
                        ZStack {
                            Circle()
                                .fill(viewModel.isRecording ? Color.red : Color.blue)
                                .frame(width: 70, height: 70)
                                .shadow(radius: 5)
                            
                            Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.bottom, 10)
                    .disabled(viewModel.isThinking)
                    
                    // Debug Info (鎖定時也可以選擇隱藏，這裡先保留方便你看)
                    if !isLocked {
                        HStack(spacing: 20) {
                            Text("🛠 IP: \(viewModel.udpService.serverIP ?? "未連線")")
                            Text("🛠 Active Table: [\(viewModel.tableId)]")
                                .foregroundColor(viewModel.tableId.isEmpty ? .red : .green)
                        }
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .padding(.bottom, 5)
                    }
                }
                .padding(.top, 10)
                .background(Color(.systemGray6))
            }
            .navigationTitle(isLocked ? "Project Akka" : "後台設定中...")
            .navigationBarTitleDisplayMode(.inline)
            // 🔥 [關鍵] 右上角加入「鎖頭按鈕」
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        // 切換鎖定狀態
                        withAnimation {
                            isLocked.toggle()
                        }
                    }) {
                        // 根據狀態換圖示
                        Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                            .foregroundColor(isLocked ? .gray : .red)
                    }
                }
            }
            .onAppear {
                editingTableId = viewModel.tableId
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
