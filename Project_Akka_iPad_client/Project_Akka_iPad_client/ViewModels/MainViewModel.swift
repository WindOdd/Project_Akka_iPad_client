import Foundation
import Combine
import AVFoundation
import UIKit
@MainActor
class MainViewModel: ObservableObject {
    // MARK: - 服務實例 (Services)
    @Published var udpService = UDPDiscoveryService()
    @Published var sttService = STTService()
    @Published var apiService = APIService()
    
    // MARK: - UI 狀態 (UI State)
    @Published var supportedGames: [GameInfo] = []
    @Published var selectedGame: GameInfo?
    @Published var chatHistory: [ChatMessage] = []
    
    // 介面控制旗標
    @Published var isThinking = false
    @Published var isRecording = false
    @Published var statusMessage = "準備中..."
    
    // 系統狀態
    @Published var sessionId = UUID().uuidString
    @Published var tableId = "T01" // 未來可從設定頁更改
    
    // MARK: - 私有屬性
    private var fillerTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private let synthesizer = AVSpeechSynthesizer()
    
    init() {
        setupBindings()
        
        // 啟動 UDP 搜尋 (App 啟動時自動執行)
        udpService.startDiscovery()
    }
    
    private func setupBindings() {
        // 1. 監聽 UDP 連線狀態
        // 一旦找到 Server IP，自動抓取遊戲列表
        udpService.$serverIP
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] ip in
                Task { await self?.refreshGames(ip: ip) }
            }
            .store(in: &cancellables)
            
        // 2. 同步 STT 狀態訊息到 ViewModel，讓 UI 顯示
        sttService.$statusMessage
            .receive(on: RunLoop.main)
            .assign(to: \.statusMessage, on: self)
            .store(in: &cancellables)
            
        // 3. 同步 STT 載入狀態，避免在載入時讓使用者按按鈕
        sttService.$isModelLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] isLoading in
                if isLoading {
                    self?.statusMessage = "模型載入中..."
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - 遊戲流程邏輯
    
    /// 刷新支援遊戲列表 (API 1)
    func refreshGames(ip: String) async {
        do {
            let games = try await apiService.fetchGames(ip: ip)
            self.supportedGames = games
            self.statusMessage = "已連線，請選擇遊戲"
        } catch {
            print("Fetch Games Error: \(error)")
            self.statusMessage = "無法取得遊戲列表"
        }
    }
    
    /// 選擇遊戲並初始化 Session (API 2 + STT Setup)
    
    func selectGame(_ game: GameInfo) async {
        self.selectedGame = game
        self.resetSession() // 切換遊戲強制重置 Session [cite: 368-370]
        
        var keywords: [String] = []
        
        // 若該遊戲支援 STT 注入，且已連線，則呼叫 API 2
        if game.enable_stt_injection, let ip = udpService.serverIP {
            do {
                keywords = try await apiService.fetchKeywords(ip: ip, gameId: game.id)
                print("取得關鍵字: \(keywords)")
            } catch {
                print("關鍵字獲取失敗，將使用預設模式: \(error)")
            }
        }
        
        // 載入模型並注入 Prompt
        await sttService.setupWhisper(keywords: keywords)
    }
    
    /// 重置對話狀態

    func resetSession() {
        self.chatHistory.removeAll()
        self.sessionId = UUID().uuidString
        self.isThinking = false
        print("Session Reset: \(self.sessionId)")
    }
    
    // MARK: - 對話互動邏輯
    
    func handleMicButtonTap() {
        if isRecording {
            stopAndSend()
        } else {
            isRecording = true
            sttService.startRecording()
        }
    }
    
    private func stopAndSend() {
        isRecording = false
        isThinking = true
        
        Task {
            // 1. 停止錄音並轉錄 (STT)
            guard let userText = await sttService.stopAndTranscribe(), !userText.isEmpty else {
                self.isThinking = false
                self.statusMessage = "聽不清楚，請再說一次"
                return
            }
            
            
            startLatencyMasking()
            

            // 注意：需將 userText 包裝進 user_input，並附帶 history (含 intent)
            let request = ChatRequest(
                table_id: tableId,
                session_id: sessionId,
                game_context: GameContext(game_name: selectedGame?.id ?? ""),
                user_input: userText,
                history: Array(chatHistory.suffix(8)) // 僅保留最近 8 筆以節省 Token
            )
            
            // 4. 發送請求
            if let ip = udpService.serverIP {
                do {
                    // 加入使用者對話 (Intent 暫為空)
                    self.chatHistory.append(ChatMessage(role: "user", content: userText, intent: ""))
                    
                    let response = try await apiService.sendChat(ip: ip, request: request)
                    
                    stopLatencyMasking()
                    
                    // 加入助手回應 (儲存 Server 回傳的 Intent)
                    self.chatHistory.append(ChatMessage(
                        role: "assistant",
                        content: response.response,
                        intent: response.intent
                    ))
                    
                    // 5. 執行 TTS 朗讀
                    speak(response.response)
                    
                } catch {
                    stopLatencyMasking()
                    print("API Error: \(error)")
                    self.statusMessage = "伺服器連線錯誤"
                }
            }
            self.isThinking = false
        }
    }
    
    // MARK: - 輔助功能 (Latency Masking & TTS)
    
    /// 啟動延遲掩蓋計時器
    private func startLatencyMasking() {
        fillerTimer?.invalidate()
        
        // T+2.5s: 第一階思考音
        fillerTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self = self, self.isThinking else { return }
            self.playFillerAudio("thinking") // 播放「嗯...」
            self.statusMessage = "阿卡正在思考..."
            
            // T+7.0s: 第二階安撫音 (可選)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { // 2.5 + 4.5 = 7.0
                if self.isThinking {
                    self.playFillerAudio("searching") // 播放「翻書聲」
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
    
    /// 本地 TTS 朗讀
    private func speak(_ text: String) {
        // 停止之前的發聲
        synthesizer.stopSpeaking(at: .immediate)
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.5 // 適中語速
        synthesizer.speak(utterance)
    }
    
    /// 播放填補音效 (Stub)
    private func playFillerAudio(_ type: String) {
        // 實際開發時，請在此處使用 AVAudioPlayer 播放 bundle 內的 mp3
        print("🎵 播放音效: \(type)")
        // 若要震動回饋也可加在這裡
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}
