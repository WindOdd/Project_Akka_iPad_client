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
            // isThinking = true // 🧪 [測試] 註解掉這行，避免它觸發任何 UI loading 遮罩
            
            Task {
                // 1. 取得 STT 文字
                guard let userText = await sttService.stopAndTranscribe(), !userText.isEmpty else {
                    DispatchQueue.main.async { self.statusMessage = "聽不清楚" }
                    return
                }
                
                // 更新 UI (顯示使用者說的話)
                DispatchQueue.main.async {
                    self.chatHistory.append(ChatMessage(role: "user", content: userText, intent: ""))
                }
                
                // 🔥🔥🔥 [請務必補上這行] 強制等待 0.6 秒 🔥🔥🔥
                // 這是讓 iOS 音訊服務（audiod）有時間重啟的關鍵，沒有它就會崩潰！
                try? await Task.sleep(nanoseconds: 600_000_000)
                
                // --- ✂️ 測試修改：跳過 API，直接復讀 ✂️ ---
                
                let echoText = "測試復讀：\(userText)"
                
                // 更新 UI (顯示助手回應)
                DispatchQueue.main.async {
                    self.chatHistory.append(ChatMessage(role: "assistant", content: echoText, intent: "test"))
                    self.statusMessage = "播放中..."
                }
                
                // 2. 直接執行 TTS 播放
                await speak(echoText)
                
                // 3. 播放後重置狀態
                DispatchQueue.main.async {
                    self.isThinking = false
                    self.statusMessage = "測試完成，可再次錄音"
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
    // 🔥 [核心修正] 修改 prepareSessionForPlayback
    nonisolated private func prepareSessionForPlayback() async {
        let session = AVAudioSession.sharedInstance()
        do {
            // 策略變更：不要先 setActive(false)，嘗試直接切換模式
            // 這通常比「關掉再開」更順暢，不會觸發 4099 錯誤
            
            // 1. 直接設定為播放模式
            // .interruptSpokenAudioAndMixWithOthers 能確保我們拿到主導權
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            
            // 2. 確保 Session 是活的
            try session.setActive(true)
            
            // 3. 給予短暫的硬體鎖定時間
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            
            print("🟢 [Audio] 無縫切換至 Playback Session 完成")
        } catch {
            print("⚠️ [Audio] 切換失敗，嘗試強制重置: \(error)")
            // 備案：如果直接切換失敗，才執行「關掉再開」的舊邏輯
            try? session.setActive(false)
            try? await Task.sleep(nanoseconds: 200_000_000)
            try? session.setCategory(.playback, mode: .spokenAudio)
            try? session.setActive(true)
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
