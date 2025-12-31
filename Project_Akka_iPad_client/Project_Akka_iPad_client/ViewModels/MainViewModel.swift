import Foundation
import Combine
import AVFoundation
import UIKit

@MainActor
class MainViewModel: ObservableObject {
    // MARK: - 服務實例
    @Published var udpService = UDPDiscoveryService()
    @Published var sttService = STTService()
    @Published var apiService = APIService()
    
    // MARK: - UI 狀態
    @Published var supportedGames: [GameInfo] = []
    @Published var selectedGame: GameInfo?
    @Published var chatHistory: [ChatMessage] = []
    
    @Published var isThinking = false
    @Published var isRecording = false
    @Published var statusMessage = "準備中..."
    @Published var sessionId = UUID().uuidString
    
    // 🔥 [修改 1] 移除 didSet，變數現在只代表「系統目前生效的值」
    // 初始化時從 UserDefaults 讀取，若無則預設 "T01"
    @Published var tableId: String = UserDefaults.standard.string(forKey: "saved_table_id") ?? "T01"
    
    // MARK: - 新增：手動儲存函式
    // 🔥 [修改 2] 只有呼叫這個函式時，才會真正修改 Table ID 並寫入磁碟
    func saveTableId(_ newId: String) {
        let trimmedId = newId.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 檢查是否為空
        guard !trimmedId.isEmpty else {
            self.statusMessage = "❌ 桌號不能為空"
            return
        }
        
        self.tableId = trimmedId
        UserDefaults.standard.set(trimmedId, forKey: "saved_table_id")
        
        // 給予 UI 回饋
        self.statusMessage = "✅ 桌號已更新為: \(trimmedId)"
        print("💾 Table ID 手動儲存確認: \(trimmedId)")
    }
    
    // ... (以下這部分保持不變) ...
    
    private var fillerTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let synthesizer = AVSpeechSynthesizer()
    
    init() {
        setupBindings()
        udpService.startDiscovery()
    }
    
    private func setupBindings() {
        // UDP 連線後自動抓取遊戲
        udpService.$serverIP
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] ip in
                Task { await self?.refreshGames(ip: ip) }
            }
            .store(in: &cancellables)
            
        // STT 狀態同步
        sttService.$statusMessage
            .receive(on: RunLoop.main)
            .assign(to: \.statusMessage, on: self)
            .store(in: &cancellables)
            
        sttService.$isModelLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] isLoading in
                if isLoading { self?.statusMessage = "模型載入中..." }
            }
            .store(in: &cancellables)
    }
    
    func refreshGames(ip: String) async {
        do {
            let games = try await apiService.fetchGames(ip: ip)
            self.supportedGames = games
            self.statusMessage = "已連線，請選擇遊戲"
        } catch {
            print("Error: \(error)")
            self.statusMessage = "無法取得遊戲列表"
        }
    }
    
    func selectGame(_ game: GameInfo) async {
        self.selectedGame = game
        self.resetSession()
        var keywords: [String] = []
        if game.enable_stt_injection, let ip = udpService.serverIP {
            do {
                keywords = try await apiService.fetchKeywords(ip: ip, gameId: game.id)
            } catch { print("KW Error: \(error)") }
        }
        await sttService.setupWhisper(keywords: keywords)
    }
    
    func resetSession() {
        self.chatHistory.removeAll()
        self.sessionId = UUID().uuidString
        self.isThinking = false
    }
    
    func handleMicButtonTap() {
        if isRecording { stopAndSend() }
        else { isRecording = true; sttService.startRecording() }
    }
    
    private func stopAndSend() {
        isRecording = false
        isThinking = true
        
        Task {
            guard let userText = await sttService.stopAndTranscribe(), !userText.isEmpty else {
                self.isThinking = false
                self.statusMessage = "聽不清楚，請再說一次"
                return
            }
            
            startLatencyMasking()
            
            let request = ChatRequest(
                table_id: self.tableId,
                session_id: sessionId,
                game_context: GameContext(game_name: selectedGame?.id ?? ""),
                user_input: userText,
                history: Array(chatHistory.suffix(8))
            )
            
            if let ip = udpService.serverIP {
                do {
                    self.chatHistory.append(ChatMessage(role: "user", content: userText, intent: ""))
                    let response = try await apiService.sendChat(ip: ip, request: request)
                    stopLatencyMasking()
                    self.chatHistory.append(ChatMessage(role: "assistant", content: response.response, intent: response.intent))
                    speak(response.response)
                } catch {
                    stopLatencyMasking()
                    self.statusMessage = "伺服器連線錯誤"
                }
            } else {
                self.statusMessage = "尚未連線到 Server"
                self.isThinking = false
            }
        }
    }
    
    private func startLatencyMasking() {
        fillerTimer?.invalidate()
        fillerTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self = self, self.isThinking else { return }
            self.playFillerAudio("thinking")
            self.statusMessage = "阿卡正在思考..."
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                if self.isThinking {
                    self.playFillerAudio("searching")
                    self.statusMessage = "阿卡正在查閱規則書..."
                }
            }
        }
    }
    
    private func stopLatencyMasking() {
        fillerTimer?.invalidate()
        fillerTimer = nil
        self.statusMessage = "阿卡就緒"
    }
    
    private func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }
    
    private func playFillerAudio(_ type: String) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}
