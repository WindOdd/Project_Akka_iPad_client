import SwiftUI
import Combine

struct ContentView: View {
    // MARK: - 1. 服務層 (Services)
    @StateObject var udpService = UDPDiscoveryService()
    @StateObject var sttService = STTService()
    @StateObject var apiService = APIService() // 👈 補上這行解決紅字
    
    // MARK: - 2. 狀態變數 (State)
    @State private var chatHistory: [ChatMessage] = []
    @State private var isRecording = false
    @State private var isThinking = false
    
    // MARK: - 3. 主畫面 (Body)
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // --- 頂部狀態列 ---
                headerView
                
                // --- 中間聊天視窗 ---
                chatScrollView
                
                // --- 底部控制區 ---
                controlArea
            }
        }
        .onAppear {
            udpService.startDiscovery()
            chatHistory.append(ChatMessage(text: "你好！我是阿卡，有什麼關於桌遊的問題都可以問我喔！", isUser: false, source: "System"))
        }
    }
    
    // MARK: - 4. 子視圖組件 (Subviews)
    
    var headerView: some View {
        VStack(spacing: 4) {
            Text("Project Akka")
                .font(.headline)
                .foregroundColor(.white)
            
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(udpService.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(udpService.statusMessage)
                }
                Divider().frame(height: 12).background(Color.gray)
                Text(sttService.statusMessage)
            }
            .font(.caption2)
            .foregroundColor(.gray)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(UIColor.systemGray6).opacity(0.1))
    }
    
    var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(chatHistory) { msg in
                        ChatBubble(message: msg) // 確保您有建立 ChatBubble.swift
                            .id(msg.id)
                    }
                    Color.clear.frame(height: 20)
                }
                .padding()
            }
            .onChange(of: chatHistory.count) { _ in
                if let lastMsg = chatHistory.last {
                    withAnimation {
                        proxy.scrollTo(lastMsg.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    var controlArea: some View {
        VStack(spacing: 16) {
            // 狀態文字提示
            if isThinking {
                HStack {
                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("阿卡正在思考...").font(.caption).foregroundColor(.gray)
                }
            } else if isRecording {
                Text("正在聆聽... (再次點擊以停止)").font(.caption).foregroundColor(.red).transition(.opacity)
            } else {
                Text("點擊按鈕開始說話").font(.caption).foregroundColor(.gray)
            }
            
            // 🎤 核心按鈕 (Toggle 模式)
            Button(action: handleButtonTap) {
                ZStack {
                    if isRecording {
                        // 錄音中的呼吸燈效果
                        Circle()
                            .stroke(Color.red.opacity(0.5), lineWidth: 4)
                            .frame(width: 88, height: 88)
                            .scaleEffect(1.1)
                            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isRecording)
                    }
                    
                    Circle()
                        .fill(buttonColor)
                        .frame(width: 80, height: 80)
                        .shadow(color: buttonColor.opacity(0.4), radius: 10, x: 0, y: 5)
                    
                    Image(systemName: buttonIcon)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .disabled(isThinking || sttService.isModelLoading)
        }
        .padding(.bottom, 30)
        .padding(.top, 10)
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - 5. 邏輯處理
    
    var buttonColor: Color {
        if isThinking { return Color.gray }
        if isRecording { return Color.red }
        return Color.blue
    }
    
    var buttonIcon: String {
        if isRecording { return "stop.fill" }
        return "mic.fill"
    }
    
    func handleButtonTap() {
        if isRecording {
            stopRecordingAndSend()
        } else {
            startRecording()
        }
    }
    
    func startRecording() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        isRecording = true
        sttService.startRecording()
    }
    
    func stopRecordingAndSend() {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.impactOccurred()
        isRecording = false
        isThinking = true
        
        Task {
            // 呼叫修正後的無參數版本
            guard let resultText = await sttService.stopAndTranscribe() else {
                isThinking = false
                return
            }
            
            if resultText.isEmpty { isThinking = false; return }
            
            chatHistory.append(ChatMessage(text: resultText, isUser: true, source: nil))
            
            guard let ip = udpService.serverIP else {
                chatHistory.append(ChatMessage(text: "尚未連線至阿卡主機，無法回答。", isUser: false, source: "System"))
                isThinking = false
                return
            }
            
            do {
                let response = try await apiService.sendChat(
                    serverIP: ip,
                    text: resultText,
                    game: "Carcassonne",
                    history: chatHistory
                )
                chatHistory.append(ChatMessage(text: response.response, isUser: false, source: response.source))
            } catch {
                chatHistory.append(ChatMessage(text: "連線錯誤：\(error.localizedDescription)", isUser: false, source: "Error"))
            }
            isThinking = false
        }
    }
}
