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
    
    // MARK: - 錄音與 TTS 流程 (核心修正區域)
    
    func handleMicButtonTap() {
        if isRecording {
            // 停止錄音
            stopAndSend()
        } else {
            // 1. UI 立即回饋
            isRecording = true
            
            // 2. 背景啟動錄音 (避免卡死 UI)
            Task {
                await sttService.startRecording()
            }
        }
    }
    
    private func stopAndSend() {
        isRecording = false
        isThinking = true
        
        Task {
            // 1. 錄音轉文字
            // (注意：STTService 內部現在會自動銷毀錄音機並關閉 Session)
            guard let userText = await sttService.stopAndTranscribe(), !userText.isEmpty else {
                self.isThinking = false
                self.statusMessage = "聽不清楚，請再說一次"
                return
            }
            
            // 2. UI 遮罩
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
                    // 更新 User 訊息
                    self.chatHistory.append(ChatMessage(role: "user", content: userText, intent: ""))
                    
                    // 3. 發送 API 請求
                    let response = try await apiService.sendChat(ip: ip, request: request)
                    
                    stopLatencyMasking()
                    self.chatHistory.append(ChatMessage(role: "assistant", content: response.response, intent: response.intent))
                    
                    // 4. [TTS 關鍵呼叫] 使用 await 確保音訊切換完成再播放
                    await speak(response.response)
                    
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
    
    // MARK: - TTS 安全播放 (🔥 徹底解決 -66748 Crash)
    
    private func speak(_ text: String) async {
        // 1. [背景] 準備播放環境
        // 這裡包含 0.5秒 的等待，是避免崩潰的關鍵
        await prepareSessionForPlayback()
        
        // 2. [主執行緒] 執行播放 (確保 Session 已就緒)
        if self.synthesizer.isSpeaking {
            self.synthesizer.stopSpeaking(at: .immediate)
        }
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.5
        
        print("🔊 [TTS] 開始朗讀: \(text.prefix(10))...")
        self.synthesizer.speak(utterance)
    }
    
    // 🔥 [核心] nonisolated: 脫離 MainActor，在背景執行
    nonisolated private func prepareSessionForPlayback() async {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // A. [雙重保險] 再次確保 Session 已關閉
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            
            // B. [魔法數字] 等待 0.5 秒 (500ms)
            // 讓 iOS 背景服務 (audiod) 有足夠時間將硬體從 16kHz 切換回 44.1kHz/48kHz
            try await Task.sleep(nanoseconds: 500_000_000)
            
            // C. 設定為純播放模式 (.playback)
            // 這是高品質 TTS 喜歡的模式
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            
            print("🟢 [Audio] Playback Session 準備就緒")
        } catch {
            print("❌ [Audio] Playback 設定失敗: \(error)")
        }
    }
    
    // MARK: - 思考模擬動畫
    
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
    
    private func playFillerAudio(_ type: String = "") {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}
