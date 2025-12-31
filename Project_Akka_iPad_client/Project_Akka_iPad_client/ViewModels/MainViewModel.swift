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
    
    @Published var tableId: String = UserDefaults.standard.string(forKey: "saved_table_id") ?? "T01"
    
    private var fillerTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let synthesizer = AVSpeechSynthesizer()
    
    init() {
        setupBindings()
        udpService.startDiscovery()
    }
    
    private func setupBindings() {
        udpService.$serverIP
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] ip in
                Task { await self?.refreshGames(ip: ip) }
            }
            .store(in: &cancellables)
            
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
    
    // MARK: - 功能操作
    
    func saveTableId(_ newId: String) {
        let trimmedId = newId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            self.statusMessage = "❌ 桌號不能為空"
            return
        }
        self.tableId = trimmedId
        UserDefaults.standard.set(trimmedId, forKey: "saved_table_id")
        self.statusMessage = "✅ 桌號已更新為: \(trimmedId)"
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
    
    // MARK: - 導航與模型管理
    
    func exitGame() {
        if isRecording { isRecording = false }
        self.isThinking = false
        self.selectedGame = nil
        self.chatHistory.removeAll()
        self.sessionId = UUID().uuidString
        self.statusMessage = "請選擇遊戲"
    }
    
    func changeModel(to model: WhisperModel) {
        exitGame()
        sttService.switchModel(to: model)
        Task { await sttService.setupWhisper(keywords: []) }
    }
    
    func reloadModel() {
        exitGame()
        sttService.resetModel()
    }
    
    // MARK: - 錄音與 TTS (🔥 修正重點)
    
    func handleMicButtonTap() {
        if isRecording { stopAndSend() }
        else { isRecording = true; sttService.startRecording() }
    }
    
    private func stopAndSend() {
        isRecording = false
        isThinking = true
        
        Task {
            // 1. 錄音轉文字 (內部會自動 deactivateSession)
            guard let userText = await sttService.stopAndTranscribe(), !userText.isEmpty else {
                self.isThinking = false
                self.statusMessage = "聽不清楚，請再說一次"
                return
            }
            
            // 2. 開始遮罩
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
                    // 更新 UI (User)
                    self.chatHistory.append(ChatMessage(role: "user", content: userText, intent: ""))
                    
                    // 3. 發送 API 請求
                    let response = try await apiService.sendChat(ip: ip, request: request)
                    
                    stopLatencyMasking()
                    self.chatHistory.append(ChatMessage(role: "assistant", content: response.response, intent: response.intent))
                    
                    // 🔥 延遲一點點，確保 Session 完全釋放
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 秒
                    
                    // 4. 開始朗讀
                    speak(response.response)
                    
                } catch {
                    stopLatencyMasking()
                    print("💥 ViewModel Error: \(error.localizedDescription)")
                    self.statusMessage = "錯誤: \(error.localizedDescription)"
                    self.isThinking = false
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
        // 🔥 1. 朗讀前：重新啟動 Session (因為錄音結束時關掉了)
        sttService.activateAudioSession()
        
        // 2. 強制在主執行緒執行，避免 unsafeForcedSync 警告
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.synthesizer.stopSpeaking(at: .immediate)
            
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
            utterance.rate = 0.5
            
            self.synthesizer.speak(utterance)
        }
    }
    
    private func playFillerAudio(_ type: String) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}
