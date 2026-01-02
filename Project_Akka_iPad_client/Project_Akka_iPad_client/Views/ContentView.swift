import SwiftUI
import AVFoundation // 👈 加入這一行，錯誤就會消失了！
struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    
    // IP 暫存
    @AppStorage("manual_server_ip") private var manualIP: String = "192.168.50.10"
    // 👇 [新增] 語音設定儲存 (自動綁定 UserDefaults)
    @AppStorage("tts_speech_rate") private var speechRate: Double = 0.5
    @AppStorage("tts_voice_identifier") private var voiceIdentifier: String = ""
    // 編輯中的 Table ID
    @State private var editingTableId: String = ""
    
    // 鎖定模式 (true=客人模式, false=管理員模式)
    @State private var isLocked: Bool = true
    
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        NavigationView {
            // B. 語速調整 Slider (細緻版)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                Text("語速微調")
                Spacer()
                                            
                // 顯示數值 (使用等寬字體避免數字跳動)
                Text(String(format: "%.2f", speechRate))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(4)
                                            
                 // 復原預設值按鈕 (當不是 0.5 時才顯示)
                 if speechRate != 0.5 {
                    Button("重置") {
                     withAnimation { speechRate = 0.5 }
                     }
                     .font(.caption2)
                     .foregroundColor(.red)
                      }
                      }
                                        
                      HStack(spacing: 12) {
                                            // 🐢 烏龜圖示 (慢)
                                            Image(systemName: "tortoise.fill")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                            
                                            // 🔥 [關鍵修改] step 改為 0.01，讓滑動超滑順
                                            Slider(value: $speechRate, in: 0.25...0.75, step: 0.01)
                                                .accentColor(.blue)
                                            
                                            // 🐇 兔子圖示 (快)
                                            Image(systemName: "hare.fill")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                            
                                            // 🔥 [新增] 試聽按鈕
                                            Button(action: {
                                                viewModel.testVoiceSettings()
                                            }) {
                                                Image(systemName: "play.circle.fill")
                                                    .resizable()
                                                    .frame(width: 30, height: 30)
                                                    .foregroundColor(.green)
                                                    .shadow(radius: 2)
                                            }
                                            .padding(.leading, 4)
                                        }
                        }
            .navigationTitle(isLocked ? "Project Akka" : "後台設定中...")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        withAnimation { isLocked.toggle() }
                    }) {
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
    
    // MARK: - Subviews
    
    // 1. 頂部設定區
    private var topSettingsArea: some View {
        VStack(spacing: 12) {
            if isLocked {
                // 🔒 鎖定狀態：只顯示基本資訊
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
                // 🔓 管理員設定模式：完整設定 + 模型管理
                VStack(spacing: 12) {
                    Text("🔧 管理員設定模式")
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // IP 設定
                    HStack {
                        Image(systemName: "network").foregroundColor(.gray)
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
                        Image(systemName: "number.square.fill").foregroundColor(.orange)
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
                    // 👇👇👇 [新增開始] 語音與語速設定區塊 👇👇👇
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack {
                                                Image(systemName: "waveform.circle.fill").foregroundColor(.blue)
                                                Text("TTS 語音設定")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            // A. 聲音選擇 Picker
                                            HStack {
                                                Text("聲音角色")
                                                Spacer()
                                                // 使用 Menu 樣式的 Picker 比較節省空間
                                                Picker("選擇聲音", selection: $voiceIdentifier) {
                                                    Text("系統預設").tag("") // 空字串代表預設
                                                    ForEach(viewModel.availableVoices, id: \.identifier) { voice in
                                                        // 顯示名稱 (如果有高品質則標註)
                                                        Text("\(voice.name) \(voice.quality == .enhanced ? "(高品質)" : "")")
                                                            .tag(voice.identifier)
                                                    }
                                                }
                                                .pickerStyle(.menu)
                                                .padding(.horizontal, 8)
                                                .background(Color.gray.opacity(0.1))
                                                .cornerRadius(8)
                                            }
                                            
                                            // B. 語速調整 Slider
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack {
                                                    Text("語速")
                                                    Spacer()
                                                    Text(String(format: "%.2f", speechRate)) // 顯示數值
                                                        .font(.caption)
                                                        .foregroundColor(.gray)
                                                }
                                                // 範圍 0.25 (慢) ~ 0.75 (快), 預設 0.5
                                                Slider(value: $speechRate, in: 0.25...0.75, step: 0.05)
                                                    .accentColor(.blue)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                        // 👆👆👆 [新增結束] 👆👆👆
                                        
                                        Divider()
                    // 🔥 [新功能] AI 模型選擇與管理 🔥
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "cpu.fill").foregroundColor(.purple)
                            Text("AI 語音模型")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            
                            // 顯示載入狀態
                            if viewModel.sttService.isModelLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("下載中...")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            
                            // 強制重載按鈕
                            Button(action: {
                                viewModel.reloadModel()
                            }) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundColor(.purple)
                            }
                            .disabled(viewModel.sttService.isModelLoading)
                        }
                        
                        // 模型選擇器
                        Picker("選擇模型", selection: Binding(
                            get: { viewModel.sttService.currentModel },
                            set: { newModel in
                                viewModel.changeModel(to: newModel)
                            }
                        )) {
                            ForEach(WhisperModel.allCases) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(viewModel.sttService.isModelLoading)
                        
                        Text("注意：切換模型需重新下載 (約 500MB~2GB)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 4)
                    
                    Divider()
                }
                .padding()
            }
        }
        .padding(.top)
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 5)
    }
    
    // 2. 遊戲選擇列表 (套用自定義按鈕樣式)
    private var gameSelectionList: some View {
        Group {
            if viewModel.supportedGames.isEmpty {
                VStack(spacing: 20) {
                    if viewModel.udpService.isConnected {
                        Text("目前沒有可用的遊戲")
                            .foregroundColor(.gray)
                    } else {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("正在搜尋遊戲主機...")
                            .foregroundColor(.gray)
                            .padding(.top, 10)
                        Text("請確保 iPad 與 Server 在同一網域")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                List {
                    ForEach(viewModel.supportedGames) { game in
                        Button(action: {
                            Task { await viewModel.selectGame(game) }
                        }) {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(game.name)
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                    Text(game.description)
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.blue.opacity(0.8))
                            }
                        }
                        .buttonStyle(GameCardButtonStyle()) // 套用點擊範圍修正
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }
    
    // 3. 聊天室介面
    private var chatInterface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
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
        }
    }
    
    // 4. 底部操作區 (包含按鈕鎖定邏輯)
    private var bottomControlArea: some View {
        let isInputBlocked = viewModel.isThinking || viewModel.sttService.isModelLoading
        return VStack {
            // 狀態文字
            if !viewModel.statusMessage.isEmpty && viewModel.selectedGame != nil {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.top, 4)
            }
            
            HStack {
                // 遊戲名稱顯示
                if let game = viewModel.selectedGame {
                    VStack(alignment: .leading) {
                        Text("正在遊玩：")
                            .font(.caption2)
                            .foregroundColor(.gray)
                        Text(game.name)
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                } else {
                    Text("請先選擇遊戲")
                        .font(.headline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // 離開按鈕
                if viewModel.selectedGame != nil {
                    Button(action: {
                        viewModel.exitGame()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.turn.up.backward.fill")
                            Text("離開")
                        }
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(16)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            
            // 🔥 [關鍵邏輯] 麥克風按鈕鎖定判斷
            // 🔥 [修改] 按鈕鎖定邏輯
                        // A. 錄音階段 (isRecording) -> 不鎖定 (要能按停止)
                        // B. 思考階段 (isThinking)  -> 鎖定 (防止重複送出)
                        // C. 說話階段 (TTS)        -> 不鎖定 (要能按打斷)
                        // D. 模型載入中             -> 鎖定 (防止錯誤)
                        

            Button(action: {
                viewModel.handleMicButtonTap()
            }) {
                ZStack {
                     // 外圈顏色與狀態：若鎖定則變灰且半透明
                    Circle()
                    .fill(
                    isInputBlocked ? Color.gray.opacity(0.3) :
                    (viewModel.isRecording ? Color.red : Color.blue)
                    )
                    .frame(width: 70, height: 70)
                    // 鎖定時移除陰影，增加「不能按」的視覺感
                    .shadow(radius: isInputBlocked ? 0 : 5)
                    if viewModel.sttService.isModelLoading {
                    ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
                    } else {
                    // 圖示邏輯
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .foregroundColor(.white)
                    // 若被鎖定，圖示也可以稍微變暗
                    .opacity(isInputBlocked ? 0.5 : 1.0)
                 }
              }
            }
            .padding(.bottom, 10)
            .padding(.top, 4)
            .disabled(isInputBlocked) // 禁止點擊
            
            // Debug Info
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
        .background(Color(.systemGray6))
    }
}

// MARK: - 自定義元件
// 請放在檔案最下方
struct GameCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle()) // 讓空白處也能點擊
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.white.opacity(0.15) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
    
}
