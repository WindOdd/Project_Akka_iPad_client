import SwiftUI
import AVFoundation // ✅ 必須加入這行

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    
    // IP 暫存
    @AppStorage("manual_server_ip") private var manualIP: String = "192.168.50.10"
    
    // 👇 語音設定儲存
    @AppStorage("tts_speech_rate") private var speechRate: Double = 0.5
    @AppStorage("tts_voice_identifier") private var voiceIdentifier: String = ""
    
    // 編輯中的 Table ID
    @State private var editingTableId: String = ""
    
    // 鎖定模式 (true=客人模式, false=管理員模式)
    @State private var isLocked: Bool = true
    
    @FocusState private var isInputFocused: Bool
    
    // MARK: - 主畫面結構 (這裡是您原本遺失的部分)
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 1. 頂部狀態/設定區
                topSettingsArea
                
                // 2. 主要內容區 (遊戲列表 vs 聊天室)
                ZStack {
                    if viewModel.selectedGame == nil {
                        gameSelectionList
                    } else {
                        chatInterface
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    isInputFocused = false
                }
                
                Divider()
                
                // 3. 底部操作區
                bottomControlArea
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
                // 🔓 管理員設定模式
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
                            // 🔥 [修正 1] 自動去除前後空白與換行，防止手殘或複製貼上的隱形字元
                            let cleanIP = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
                            // 將清理後的 IP 存回變數 (讓使用者看到改變)
                            manualIP = cleanIP
                            if !cleanIP.isEmpty {
                           // 🔥 [修正 2] 只更新變數，不要在這裡呼叫 refreshGames
                           // 因為 MainViewModel 已經有綁定 udpService.serverIP 的監聽了
                        // 這樣可以避免「按一下跑兩次」的 Bug
                            viewModel.udpService.serverIP = cleanIP
                            print("🔗 [Manual Connect] 設定 IP 為: \(cleanIP)，等待監聽器觸發連線...")
                            }
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
                    
                    // 👇👇👇 [修正] 語音設定區塊 (這才是它該在的位置) 👇👇👇
                    VStack(spacing: 10) {
                        // 第一行：標題 + 聲音選擇 (整合在一行)
                        HStack {
                            Image(systemName: "waveform.circle.fill").foregroundColor(.blue)
                            Text("TTS 設定").font(.caption).bold().foregroundColor(.secondary)
                            
                            Spacer()
                            
                            // 聲音選擇器
                            Picker("選擇聲音", selection: $voiceIdentifier) {
                                Text("系統預設").tag("")
                                ForEach(viewModel.availableVoices, id: \.identifier) { voice in
                                    Text("\(voice.name)").tag(voice.identifier)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .scaleEffect(0.9)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)
                        }
                        
                        // 第二行：語速滑桿 + 數值 + 試聽 (整合在一行)
                        HStack(spacing: 8) {
                            Text("語速").font(.caption).foregroundColor(.gray)
                            
                            Image(systemName: "tortoise.fill").font(.caption2).foregroundColor(.gray)
                            
                            // 🔥 Slider 間距設為 0.01 (精細微調)
                            Slider(value: $speechRate, in: 0.25...0.75, step: 0.01)
                            
                            Image(systemName: "hare.fill").font(.caption2).foregroundColor(.gray)
                            
                            // 數值顯示
                            Text(String(format: "%.2f", speechRate))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.blue)
                                .frame(width: 35)
                            
                            // 試聽按鈕
                            Button(action: { viewModel.testVoiceSettings() }) {
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    // 👆👆👆 [修正結束] 👆👆👆
                    
                    Divider()
                    
                    // AI 模型設定
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "cpu.fill").foregroundColor(.purple)
                            Text("AI 語音模型")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            
                            if viewModel.sttService.isModelLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("下載中...")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            
                            Button(action: {
                                viewModel.reloadModel()
                            }) {
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundColor(.purple)
                            }
                            .disabled(viewModel.sttService.isModelLoading)
                        }
                        
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
    
    // 2. 遊戲選擇列表
    private var gameSelectionList: some View {
        Group {
            if viewModel.supportedGames.isEmpty {
                VStack(spacing: 20) {
                    if viewModel.udpService.isConnected {
                        Text("目前沒有可用的遊戲")
                            .foregroundColor(.gray)
                    } else {
                        ProgressView().scaleEffect(1.5)
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
                        .buttonStyle(GameCardButtonStyle())
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
    
    // 4. 底部操作區
    private var bottomControlArea: some View {
        let isInputBlocked = viewModel.isThinking || viewModel.sttService.isModelLoading
        
        return VStack {
            if !viewModel.statusMessage.isEmpty && viewModel.selectedGame != nil {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.top, 4)
            }
            
            HStack {
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
            
            Button(action: {
                viewModel.handleMicButtonTap()
            }) {
                ZStack {
                    Circle()
                        .fill(
                            isInputBlocked ? Color.gray.opacity(0.3) :
                            (viewModel.isRecording ? Color.red : Color.blue)
                        )
                        .frame(width: 70, height: 70)
                        .shadow(radius: isInputBlocked ? 0 : 5)
                    
                    if viewModel.sttService.isModelLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                    } else {
                        Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .opacity(isInputBlocked ? 0.5 : 1.0)
                    }
                }
            }
            .padding(.bottom, 10)
            .padding(.top, 4)
            .disabled(isInputBlocked)
            
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

struct GameCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color.white.opacity(0.15) : Color.clear)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.2), value: configuration.isPressed)
    }
}
