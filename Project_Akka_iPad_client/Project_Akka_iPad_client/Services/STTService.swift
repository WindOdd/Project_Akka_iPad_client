import Foundation
import AVFoundation
import WhisperKit
import Combine

// MARK: - 模型定義
enum WhisperModel: String, CaseIterable, Identifiable {
    // 🔥 [新加入] 您指定的 594MB Distil 模型 (非 Turbo，可能更穩)
    case distilLargeV3_594MB = "distil-whisper_distil-large-v3_594MB"
    
    // 之前的選項
    case openaiLargeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case largeV3Turbo600MB = "distil-whisper_distil-large-v3_turbo_600MB"
    
    // 備用
    case medium = "medium"
    case base = "base"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .distilLargeV3_594MB: return "Distil V3 (594MB) 🆕"
        case .openaiLargeV3Turbo: return "OpenAI Turbo (632MB)"
        case .largeV3Turbo600MB: return "Distil Turbo (600MB)"
        case .medium: return "Medium (平衡)"
        case .base: return "Base (快速)"
        }
    }
}

@MainActor
class STTService: ObservableObject {
    // MARK: - Published States
    @Published var isModelLoading = false
    @Published var statusMessage = "等待選擇遊戲..."
    
    @Published var currentModel: WhisperModel = {
        if let saved = UserDefaults.standard.string(forKey: "selected_whisper_model"),
           let model = WhisperModel(rawValue: saved) {
            return model
        }
        // 🔥 預設改為您想測試的這個新模型
        return .distilLargeV3_594MB
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
            
            // 🔥 [Warmup] 熱身：對 A16 晶片非常重要，避免第一次卡頓
            self.statusMessage = "正在為晶片最佳化 (熱身中)..."
            print("🔥 開始模型熱身 (Warmup)...")
            try? await pipe?.transcribe(audioArray: [Float](repeating: 0, count: 16000))
            
            self.isModelLoading = false
            self.statusMessage = "阿卡就緒"
            print("✅ 模型載入與熱身完成")
            
        } catch {
            self.statusMessage = "載入失敗: \(error.localizedDescription)"
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
            
            // Whisper 偏好 16kHz
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
        
        // 🔥🔥 [關鍵修正] 啟用 Prompt (之前被寫成 let _ = ... 導致被丟棄)
        let promptText = "繁體中文桌遊對話。請使用繁體中文回答。關鍵詞：\(currentKeywords.joined(separator: ", "))"
        
        // 將文字轉為 Token
        var promptTokens: [Int] = []
        if let tokenizer = pipe.tokenizer {
            promptTokens = tokenizer.encode(text: promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            
            print("ℹ️ [Prompt] 啟用成功，Token 數: \(promptTokens.count)")
        } else {
            print("⚠️ [Prompt] Tokenizer 失效，Prompt 未啟用")
        }
        
        // 🔥🔥 [關鍵修正] 設定 DecodingOptions
        let options = DecodingOptions(
            language: "zh",
            temperature: 0.0,
            promptTokens: promptTokens, // 👈 必須傳入這個，Distil 才會講中文
            
            // 👇 解決「錄不到聲音」或「回傳 nil」的關鍵參數
            logProbThreshold: -20.0, // 設為極低，強迫模型吐出文字
            noSpeechThreshold: 0.95  // 提高靜音門檻
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
