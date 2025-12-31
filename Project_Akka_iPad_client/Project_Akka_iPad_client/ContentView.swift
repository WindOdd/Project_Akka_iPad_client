import SwiftUI
import Combine

struct ContentView: View {
    @StateObject var udpService = UDPDiscoveryService()
    @StateObject var sttService = STTService()
    @StateObject var apiService = APIService()
    @State private var chatHistory: [ChatMessage] = []
    @State private var isRecording = false
    @State private var isThinking = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                headerView
                chatScrollView
                controlArea
            }
        }
        .onAppear { udpService.startDiscovery() }
    }

    // --- UI 元件 ---
    var headerView: some View {
        VStack {
            Text("Project Akka").font(.headline).foregroundColor(.white)
            Text("\(udpService.statusMessage) | \(sttService.statusMessage)")
                .font(.caption2).foregroundColor(.gray)
        }
        .padding().frame(maxWidth: .infinity).background(Color.white.opacity(0.1))
    }

    var chatScrollView: some View {
        ScrollView {
            LazyVStack {
                ForEach(chatHistory) { msg in
                    ChatBubble(message: msg)
                }
            }
            .padding()
        }
    }

    var controlArea: some View {
        VStack(spacing: 20) {
            Button(action: handleButtonTap) {
                ZStack {
                    Circle().fill(isRecording ? Color.red : Color.blue).frame(width: 120, height: 120)
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill").font(.largeTitle).foregroundColor(.white)
                }
            }
            .disabled(isThinking || sttService.isModelLoading)
        }
        .padding(.bottom, 30)
    }

    // --- 邏輯 ---
    func handleButtonTap() {
        if isRecording { stopRecordingAndSend() }
        else { isRecording = true; sttService.startRecording() }
    }

    func stopRecordingAndSend() {
        isRecording = false
        isThinking = true
        Task {
            // 呼叫昨天測試成功的無參數版本
            guard let text = await sttService.stopAndTranscribe(), !text.isEmpty else {
                isThinking = false
                return
            }
            chatHistory.append(ChatMessage(text: text, isUser: true, source: nil))
            
            if let ip = udpService.serverIP {
                // 呼叫簡單版 API
                if let response = try? await apiService.sendChat(serverIP: ip, text: text) {
                    chatHistory.append(ChatMessage(text: response.response, isUser: false, source: response.source))
                }
            }
            isThinking = false
        }
    }
}
