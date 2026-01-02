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
    //private let synthesizer = AVSpeechSynthesizer()
    // ✅ [修正] 只保留一個 synthesizer 實例，避免衝突
    private var synthesizer: AVSpeechSynthesizer?
    
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
        // 🔥 [新增] 強制打斷機制
        // 如果正在講話，允許使用者按下按鈕強制停止播放並開始錄音
        // 🔧 [修正] 使用統一的 synthesizer 實例
        if synthesizer?.isSpeaking ?? false {
            print("🛑 [測試] 強制中斷說話")
            synthesizer?.stopSpeaking(at: .immediate)
        }

        if isRecording {
            stopAndSend()
        } else {
            isRecording = true
            Task {
                await sttService.startRecording()
            }
        }
    }
    
    // MainViewModel.swift

    private func stopAndSend() {
            isRecording = false
            // 啟動思考動畫 (這會觸發 2.5s 後的 filler sound)
            self.isThinking = true
            self.startLatencyMasking()
            
            Task {
                // 1. 取得 STT 文字
                guard let userText = await sttService.stopAndTranscribe(), !userText.isEmpty else {
                    DispatchQueue.main.async {
                        self.isThinking = false
                        self.stopLatencyMasking()
                        self.statusMessage = "聽不清楚，請再試一次"
                    }
                    return
                }
                
                // 更新 UI (User)
                let userMsg = ChatMessage(role: "user", content: userText, intent: "")
                DispatchQueue.main.async {
                    self.chatHistory.append(userMsg)
                }
                
                // 2. 準備 API Request
                // 確保有選中遊戲與 IP
                guard let game = selectedGame, let ip = udpService.serverIP else {
                    DispatchQueue.main.async {
                        self.statusMessage = "連線錯誤：無 IP 或未選擇遊戲"
                        self.isThinking = false
                    }
                    return
                }
                
                let request = ChatRequest(
                    table_id: self.tableId,
                    session_id: self.sessionId,
                    game_context: GameContext(game_name: game.id),
                    user_input: userText,
                    history: self.chatHistory // 包含剛加入的 userMsg
                )
                
                // 3. 呼叫 API
                do {
                    let response = try await apiService.sendChat(ip: ip, request: request)
                    
                    // 收到回應，停止 Masking
                    self.stopLatencyMasking()
                    
                    DispatchQueue.main.async {
                        self.isThinking = false
                        // 更新 UI (Assistant)
                        let aiMsg = ChatMessage(role: "assistant", content: response.response, intent: response.intent)
                        self.chatHistory.append(aiMsg)
                        self.statusMessage = "阿卡說話中..."
                    }
                    
                    // 4. 播放 TTS (直接播放 API 回傳的文字)
                    await speak(response.response)
                    
                } catch {
                    print("API Error: \(error)")
                    self.stopLatencyMasking()
                    DispatchQueue.main.async {
                        self.isThinking = false
                        self.statusMessage = "連線逾時或錯誤"
                        // 錯誤時也可以唸出來 (選擇性)
                        Task { await self.speak("抱歉，連線好像有點問題，請再試一次。") }
                    }
                }
            }
        }
    
    // MARK: - TTS 安全播放 (🔥 徹底解決 -66748 Crash)
    
    private func speak(_ text: String) async {
            // 1. [背景] 準備播放環境 (包含 0.5s 等待，幫 TTS 鋪路)
            if let oldSynth = self.synthesizer {
                oldSynth.stopSpeaking(at: .immediate)
                self.synthesizer = nil
            }
            
            // 呼叫我們寫好的鋪路函式
            await prepareSessionForPlayback()
            
            // 2. [主執行緒] 重建 Synthesizer
            if let oldSynth = self.synthesizer, oldSynth.isSpeaking {
                oldSynth.stopSpeaking(at: .immediate)
            }
            
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s 緩衝
            
            // 建立全新的實例
            let newSynthesizer = AVSpeechSynthesizer()
            
            // ❌❌❌ [關鍵修正：請刪除或註解掉這行] ❌❌❌
            // newSynthesizer.usesApplicationAudioSession = false
            // 註解掉它，代表 "usesApplicationAudioSession = true" (預設值)
            // 意思就是：「好，我聽你的，我用你準備好的 Session。」
            
            self.synthesizer = newSynthesizer

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            
            print("🔊 [TTS] 嘗試播放 (使用 Shared Session): \(text.prefix(10))...")
            newSynthesizer.speak(utterance)
        }

    
    // 🔥 [核心] nonisolated: 脫離 MainActor，在背景執行
    /// 🔥 [修改] 不再切換 Category，只確保 Active 與正確的路由
        nonisolated private func prepareSessionForPlayback() async {
            let session = AVAudioSession.sharedInstance()
            do {
                // 再次確認它是 PlayAndRecord (防止被其他 App 改掉)
                // 並且再次確保 defaultToSpeaker，以免聲音從聽筒出來
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
            } catch {
                print("⚠️ [Audio] Session 檢查失敗: \(error)")
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
