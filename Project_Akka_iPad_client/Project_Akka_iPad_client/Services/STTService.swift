import Foundation
import AVFoundation
import WhisperKit
import Combine

// MARK: - 模型定義
enum WhisperModel: String, CaseIterable, Identifiable {
    // 🔥 唯一推薦：OpenAI 官方 Turbo 量化版 (626MB)
    case openaiLargeV3Turbo_626MB = "openai_whisper-large-v3-v20240930_626MB"
    
    // 備用
    case small = "small"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .openaiLargeV3Turbo_626MB: return "OpenAI Turbo (626MB 👑)"
        case .small: return "Small (備用)"
        }
    }
}

@MainActor
class STTService: ObservableObject {
    // MARK: - Published States
    @Published var isModelLoading = false
    @Published var statusMessage = "等待選擇遊戲..."
    
    @Published var currentModel: WhisperModel = {
        // 🔥 強制鎖定為 OpenAI Turbo
        return .openaiLargeV3Turbo_626MB
    }()
    
    // MARK: - Internal Properties
    private var pipe: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var audioFilename: URL?
    private var currentKeywords: [String] = []
    
    // MARK: - 模型生命週期管理
    
    func setupWhisper(keywords: [String]) async {
        self.currentKeywords = keywords
        
        if pipe != nil {
            print("✅ 模型實體已存在，僅更新關鍵字")
            return
        }
        
        self.isModelLoading = true
        self.statusMessage = "下載模型: \(currentModel.displayName)..."
        
        do {
            print("🚀 開始載入模型: \(currentModel.rawValue)")
            pipe = try await WhisperKit(model: currentModel.rawValue, download: true)
            
            // 🔥 [Warmup] 熱身
            self.statusMessage = "正在為 A16 晶片最佳化 (熱身中)..."
            print("🔥 開始模型熱身 (Warmup)...")
            try? await pipe?.transcribe(audioArray: [Float](repeating: 0, count: 16000))
            
            self.isModelLoading = false
            self.statusMessage = "阿卡就緒"
            print("✅ 模型載入與熱身完成")
            
        } catch {
            self.statusMessage = "載入失敗: 請檢查網路或重啟 App"
            print("❌ Whisper load error: \(error)")
            self.isModelLoading = false
        }
    }
    
    func switchModel(to newModel: WhisperModel) {
        if newModel == currentModel && pipe != nil { return }
        print("🔄 切換模型至: \(newModel.rawValue)")
        currentModel = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: "selected_whisper_model")
        resetModel()
        statusMessage = "切換至 \(newModel.displayName)..."
    }
    
    func resetModel() {
        pipe = nil
        print("🗑 模型記憶體已釋放")
    }
    
    // MARK: - Audio Session Management
    
    @MainActor
    func configureAlwaysOnSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ [Audio] Session 設定為 Always-On PlayAndRecord")
        } catch {
            print("❌ [Audio] Session 設定失敗: \(error)")
        }
    }
    
    // MARK: - Recording Logic
    
    func startRecording() async {
        print("🎙️ 準備啟動錄音流程...")
        
        await MainActor.run {
            configureAlwaysOnSession()
        }
        
        let recorder = await Task.detached(priority: .userInitiated) { () -> AVAudioRecorder? in
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("input.wav")
            
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            do {
                return try AVAudioRecorder(url: url, settings: settings)
            } catch {
                print("❌ 錄音初始化失敗: \(error)")
                return nil
            }
        }.value
        
        if let validRecorder = recorder {
            self.audioRecorder = validRecorder
            self.audioFilename = validRecorder.url
            
            if validRecorder.record() {
                print("🎙️ 錄音正式開始")
            } else {
                print("❌ 呼叫 record() 失敗")
                self.statusMessage = "無法啟動錄音"
            }
        } else {
            self.statusMessage = "錄音啟動失敗"
        }
    }
    
    func stopAndTranscribe() async -> String? {
        // 1. 停止錄音
        audioRecorder?.stop()
        audioRecorder = nil
        print("⏹️ 錄音機實例已銷毀")
        
        guard let pipe = pipe, let url = audioFilename else { return nil }
        
        // 檔案檢查
        do {
            if !FileManager.default.fileExists(atPath: url.path) { return nil }
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            if (attr[.size] as? UInt64 ?? 0) < 4096 { return nil }
        } catch { return nil }
        
        // 🔥 [Prompt] 防止變英文
        let promptText = "繁體中文桌遊對話。請使用繁體中文回答。關鍵詞：\(currentKeywords.joined(separator: ", "))"
        
        var promptTokens: [Int] = []
        if let tokenizer = pipe.tokenizer {
            promptTokens = tokenizer.encode(text: promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            print("ℹ️ [Prompt] 啟用成功，Tokens數量: \(promptTokens.count)")
        }
        
        // 🔥🔥 [極限修正] Turbo 模型超級靈敏設定 🔥🔥
        let options = DecodingOptions(
            language: "zh",
            temperature: 0.0,
            promptTokens: promptTokens,
            
            // 1. 強制忽略信心分數 (設為 -100.0)
            // 只要有聲音，不管模型多沒把握，都要吐出文字
            compressionRatioThreshold: 2.4,
            logProbThreshold: -100.0,
            
            // 2. 極限靜音門檻
            // 除非 99.5% 確定是靜音，否則都視為有說話
            noSpeechThreshold: 0.995,
            
            // 3. 避免無窮迴圈
        )
        
        print("📝 開始辨識 (Model: \(currentModel.displayName))")
        
        do {
            let result = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
            let text = result.first?.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            print("📝 [Whisper 辨識結果]: \(text ?? "nil")")
            
            if let t = text, (t.isEmpty || t == "you" || t.lowercased().contains("thank you")) {
                 return nil
            }
            return (text?.isEmpty ?? true) ? nil : text
        } catch {
            print("❌ 辨識失敗: \(error)")
            return nil
        }
    }
}
