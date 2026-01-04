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
    // 👇 [新增 1] 儲存可用的中文語音列表
    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published var isThinking = false
    @Published var isRecording = false
    @Published var statusMessage = "準備中..."
    @Published var sessionId = UUID().uuidString
    
    @Published var tableId: String = UserDefaults.standard.string(forKey: "saved_table_id") ?? "T01"
    // 👇 [新增 1] 加入錄音計時器變數
    private var recordingTimer: Timer?
    private var fillerTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    // ✅ [修正] 只保留一個 synthesizer 實例，避免衝突
    private let synthesizer = AVSpeechSynthesizer()
    
    init() {
            setupBindings()
            udpService.startDiscovery()
            // 👇 [新增 2] 載入支援的語音清單
            loadVoices()
            // 🔥 [新增] 讓 TTS 代理人綁定 (選配，若未來需要監聽播放結束)
            // synthesizer.delegate = self
    }
    // 👇 [新增] 抓取系統內的 zh-TW 語音
        private func loadVoices() {
            // 過濾出所有繁體中文語音
            let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "zh-TW" }
            self.availableVoices = voices
            print("🗣️ 載入語音數量: \(voices.count)")
        }

        // 👇 [新增] 讀取 UserDefaults 設定並套用
        private func applyUserVoiceSettings(to utterance: AVSpeechUtterance) {
            // A. 設定聲音 (Voice)
            let savedVoiceId = UserDefaults.standard.string(forKey: "tts_voice_identifier") ?? ""
            if !savedVoiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: savedVoiceId) {
                utterance.voice = voice
            } else {
                // 預設 fallback
                utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
            }
            
            // B. 設定語速 (Rate)
            // AVSpeechUtteranceDefaultSpeechRate 約為 0.5
            let savedRate = UserDefaults.standard.float(forKey: "tts_speech_rate")
            if savedRate > 0.0 {
                utterance.rate = savedRate
            } else {
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            }
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
            
            // 1. 先切換設定 (這是同步的，馬上執行)
            sttService.switchModel(to: model)
            
            // 2. 開啟一個背景任務來「等待」與「重新載入」
            Task {
                // ✅ 正確！在 Task 裡面才能使用 await
                print("⏳ 等待 ANE 資源釋放...")
                try? await Task.sleep(nanoseconds: 1_500_000_000) // 等待 1.5 秒
                
                // 3. 休息完後，開始載入新模型
                await sttService.setupWhisper(keywords: [])
            }
        }
    
    func reloadModel() {
        exitGame()
        sttService.resetModel()
    }
    
    // MARK: - 錄音與 TTS 流程 (核心修正區域)
    
    func handleMicButtonTap() {
            // 🔥 [修改] 不再需要解包 (?)
            if synthesizer.isSpeaking {
                print("🛑 [User Action] 強制中斷 TTS")
                synthesizer.stopSpeaking(at: .immediate)
            }

            if isRecording {
                stopAndSend()
            } else {
                isRecording = true
                startRecordingTimer()
                Task {
                    await sttService.startRecording()
                }
            }
        }
    
    // MainViewModel.swift

    private func stopAndSend() {
            recordingTimer?.invalidate()
            recordingTimer = nil
            isRecording = false
            // 啟動思考動畫 (這會觸發 2.5s 後的 filler sound)
            self.isThinking = true
            self.startLatencyMasking()
            
            Task {
                // 1. 取得 STT 文字
                guard let userText = await sttService.stopAndTranscribe(), !userText.isEmpty else {
                    //DispatchQueue.main.async {
                        self.isThinking = false
                        self.stopLatencyMasking()
                        self.statusMessage = "聽不清楚，請再試一次"
                    //}
                    return
                }
                
                // 更新 UI (User)
                let userMsg = ChatMessage(role: "user", content: userText, intent: "")
                //DispatchQueue.main.async {
                self.chatHistory.append(userMsg)
                //}
                
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
                                    
                                    // 更新 UI
                                    self.isThinking = false
                                    let aiMsg = ChatMessage(role: "assistant", content: response.response, intent: response.intent)
                                    self.chatHistory.append(aiMsg)
                                    self.statusMessage = "阿卡說話中..."
                                    
                                    // ==========================================
                                    // 🛡️ 步驟 1: 資源釋放 (標準程序)
                                    // ==========================================
                                    self.sttService.forceReleaseAudioResources()
                                    print("--- [Debug] 資源釋放完畢 (setActive: false)，緩衝等待 (0.6s) ---")
                                    try? await Task.sleep(nanoseconds: 600_000_000)
                                    
                                    // ============================================================
                                    // 🔬 [深度診斷模式] System Status Snapshot
                                    // ============================================================
                                    
                                    print("\n🔍 ======== [診斷開始: 尋找 -66748 元兇] ========")
                                    
                                    let textToSpeak = response.response
                                    
                                    await MainActor.run {
                                        let session = AVAudioSession.sharedInstance()
                                        
                                        // 1. [檢查點 A] 初始狀態 (在任何修改之前)
                                        // 如果這裡是 PlayAndRecord，代表之前的釋放失敗
                                        print("1️⃣ [初始狀態檢查]")
                                        print("   - Category: \(session.category.rawValue)")
                                        print("   - Mode: \(session.mode.rawValue)")
                                        // isOtherAudioPlaying 有時能反映系統是否還咬著資源
                                        print("   - OtherAudioPlaying: \(session.isOtherAudioPlaying)")
                                        
                                        // 檢查路由：如果是 'Receiver' (聽筒)，代表路由卡死，這會導致 TTS 失敗
                                        let currentRoute = session.currentRoute.outputs.first?.portName ?? "None"
                                        print("   - Current Route: \(currentRoute)")
                                        if currentRoute == "Receiver" {
                                            print("   ⚠️ 警告: 路由卡在聽筒 (Receiver)，TTS 將無法透過喇叭播放！")
                                        }
                                        
                                        // 2. [行動] 執行標準修復程序 (切換為 .playback)
                                        print("\n2️⃣ [執行設定: .playback]")
                                        do {
                                            // 🔥 強制設定為 .playback (純播放)，完全避開麥克風
                                            try session.setCategory(.playback, mode: .default, options: [])
                                            try session.setActive(true, options: .notifyOthersOnDeactivation)
                                            print("   ✅ Session 設定成功 (.playback)")
                                        } catch {
                                            print("   ❌ Session 設定失敗: \(error)")
                                        }
                                        
                                        // 3. [檢查點 B] 設定後狀態確認
                                        print("\n3️⃣ [設定後狀態確認]")
                                        print("   - Category: \(session.category.rawValue) (預期: AVAudioSessionCategoryPlayback)")
                                        print("   - Mode: \(session.mode.rawValue) (預期: AVAudioSessionModeDefault)")
                                        print("   - Current Route: \(session.currentRoute.outputs.first?.portName ?? "None")")
                                        
                                        // 4. [測試 A] 檢查舊的 Synthesizer (看看它是不是已經壞了)
                                        print("\n4️⃣ [測試 A: 檢查舊實體狀態]")
                                        // 印出記憶體位址，確認我們用的是原本那個
                                        let oldPtr = Unmanaged.passUnretained(self.synthesizer).toOpaque()
                                        print("   - Old Synthesizer Ptr: \(oldPtr)")
                                        print("   - IsSpeaking: \(self.synthesizer.isSpeaking)")
                                        print("   - IsPaused: \(self.synthesizer.isPaused)")
                                        // 我們不呼叫舊的 speak，避免干擾，但如果下面的測試成功，代表舊實體確實有問題
                                        
                                        // 5. [測試 B] 建立全新實體 (終極測試)
                                        // 如果這一步成功發聲且無錯誤，證明解法是「每次播放都重建 Synthesizer」
                                        print("\n5️⃣ [測試 B: 建立全新 Synthesizer]")
                                        
                                        let cleanSynthesizer = AVSpeechSynthesizer()
                                        let utterance = AVSpeechUtterance(string: textToSpeak)
                                        
                                        // 套用您的語音設定邏輯 (手動複製過來以確保變數隔離)
                                        let savedVoiceId = UserDefaults.standard.string(forKey: "tts_voice_identifier") ?? ""
                                        if !savedVoiceId.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: savedVoiceId) {
                                            utterance.voice = voice
                                        } else {
                                            utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
                                        }
                                        let savedRate = UserDefaults.standard.float(forKey: "tts_speech_rate")
                                        utterance.rate = savedRate > 0.0 ? savedRate : AVSpeechUtteranceDefaultSpeechRate
                                        
                                        print("   🔊 [Action] 呼叫 cleanSynthesizer.speak...")
                                        cleanSynthesizer.speak(utterance)
                                        
                                        // ⚠️ [重要] 延長區域變數生命週期 (Life Cycle Extension)
                                        // 這是為了防止 cleanSynthesizer 在話還沒講完就被釋放
                                        // 在 Debug 模式下我們用簡單的 Delay 來測試，正式版會改寫法
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                                            // 只要引用它，它就不會死
                                            _ = cleanSynthesizer
                                            print("   🏁 [診斷結束] 測試區塊生命週期結束")
                                        }
                                        
                                        self.statusMessage = "診斷測試中..."
                                    }
                                    print("🔍 ==============================================\n")
                } catch {
                    print("API Error: \(error)")
                    self.stopLatencyMasking()
                    //DispatchQueue.main.async {
                    self.isThinking = false
                    self.statusMessage = "連線逾時或錯誤"
                    // 錯誤時也可以唸出來 (選擇性)
                    Task { await self.speak("抱歉，連線好像有點問題，請再試一次。") }
                    //}
                }
            }
        }
    
    // 👇 [新增 4] 實作 Timeout 邏輯與震動
        private func startRecordingTimer() {
            recordingTimer?.invalidate() // 防禦性清除
            
            // 設定 60 秒後觸發
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleRecordingTimeout()
                }
            }
        }
    private func handleRecordingTimeout() {
            guard isRecording else { return } // 確保還在錄音中
            
            print("⏰ 錄音超時 (60s)，強制送出")
            self.statusMessage = "錄音超時，自動送出..."
            
            // 📳 觸發長震動提示 (Warning 類型震動比較明顯)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            
            // 執行送出流程
            stopAndSend()
        }
    
    // MARK: - TTS (Singleton Strategy)
        
        private func speak(_ text: String) async {
            // 1. 如果正在說話，先停止
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            
            // 2. 確保 Session 狀態
            await MainActor.run {
                prepareSessionForPlayback()
            }
            
            // 3. 建立發音內容
            let utterance = AVSpeechUtterance(string: text)
            
            // 🔥 [修改] 套用使用者設定的聲音與語速
            applyUserVoiceSettings(to: utterance)
            
            print("🔊 [TTS] 播放 (Voice: \(utterance.voice?.name ?? "Default"), Rate: \(utterance.rate)): \(text.prefix(10))...")
            
            // 🔥 [關鍵] 直接使用常駐的 synthesizer 實體
            synthesizer.speak(utterance)
            
            // 4. 更新 UI
            DispatchQueue.main.async {
                self.statusMessage = "您可以繼續提問..."
            }
        }
    
    // 🔥 [核心] nonisolated: 脫離 MainActor，在背景執行
    /// 🔥 [修改] 不再切換 Category，只確保 Active 與正確的路由
        @MainActor
        private func prepareSessionForPlayback() {
            let session = AVAudioSession.sharedInstance()
            do {
                // 確保是 PlayAndRecord + DefaultToSpeaker
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
    func testVoiceSettings() {
            Task {
                // 隨機講一句話，讓使用者確認語速
                let testPhrases = [
                    "你好，這是目前的語速"
                ]
                let text = testPhrases.randomElement() ?? "語速測試"
                await speak(text)
            }
        }
}
