import Foundation
import AVFoundation
import WhisperKit
import Combine

// MARK: - 模型定義
enum WhisperModel: String, CaseIterable, Identifiable {
    case openaiLargeV3Turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case largeV3Turbo600MB = "distil-whisper_distil-large-v3_turbo_600MB"
    case base = "base"
    case small = "small"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .largeV3Turbo600MB: return "Large V3 Turbo (600MB 👑推薦)"
        case .openaiLargeV3Turbo: return "Large V3 Turbo (632MB)"
        case .base: return "Base (快速)"
        case .small: return "Small (極速)"
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
        return .largeV3Turbo600MB
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
                
                // 🔥 [新增] 自動熱身 (Warmup)
                // 在使用者還沒開始說話前，先強制執行一次空辨識，觸發 ANE 編譯
                self.statusMessage = "正在為 A16 晶片最佳化 (熱身中)..."
                print("🔥 開始模型熱身 (Warmup)...")
                
                // 建立一個極短的靜音音訊進行熱身
                // 這裡我們簡單地讓它 transcribe 一個空路徑或是極短的 dummy 檔案，
                // 但最簡單的方法是讓它跑一次空的 decode (如果 WhisperKit 支援)
                // 或是直接告訴使用者「準備完成」但心裡知道第一次會慢。
                //
                // 比較正規的做法是：
                try? await pipe?.transcribe(audioArray: [Float](repeating: 0, count: 16000)) // 1秒靜音
                
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
        statusMessage = "已切換至 \(newModel.rawValue)，正在準備下載..."
    }
    
    func resetModel() {
        pipe = nil
        print("🗑 模型記憶體已釋放")
    }
    
    // MARK: - Audio Session Management (錄音專用)
        
        /// 🔥 [修改] 配置常駐型 Session
        /// 策略：設定為 PlayAndRecord + DefaultToSpeaker，同時滿足錄音與 TTS 擴音需求
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

        /// 🔥 [修改] 停用功能改為空實作
        /// 策略：永遠不關閉 Session，避免硬體重啟導致的 Crash
        func deactivateSession() async {
            // No-op: 保持 Session 開啟
            print("🛡️ [Audio] 忽略停用請求 (Always-On Strategy)")
        }
    
    
    // MARK: - Recording Logic
    
    func startRecording() async {
        print("🎙️ 準備啟動錄音流程...")
        
        // 🔧 [修正] 直接在背景執行 async 函數，不再使用 detached task 以避免 actor isolation 問題
        // 1. 啟動 Session (async)
        await MainActor.run {
                    configureAlwaysOnSession()
                }
        
        let recorder = await Task.detached(priority: .userInitiated) { () -> AVAudioRecorder? in
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("input.wav")
            
            // 2. 設定錄音參數 (Whisper 偏好 16kHz)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            do {
                let newRecorder = try AVAudioRecorder(url: url, settings: settings)
                return newRecorder
            } catch {
                print("❌ 錄音初始化失敗: \(error)")
                return nil
            }
        }.value
        
        if let validRecorder = recorder {
            self.audioRecorder = validRecorder
            self.audioFilename = validRecorder.url
            
            // record() 建議在 Main Thread 或由 Recorder 實例所在的 Context 呼叫
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
            audioRecorder = nil // 釋放資源
            print("⏹️ 錄音機實例已銷毀")
            
            guard let pipe = pipe, let url = audioFilename else { return nil }
            
            // 檔案檢查
            do {
                if !FileManager.default.fileExists(atPath: url.path) { return nil }
                let attr = try FileManager.default.attributesOfItem(atPath: url.path)
                if (attr[.size] as? UInt64 ?? 0) < 4096 { return nil }
            } catch { return nil }
            
            // 2. 準備提示詞 (Prompt)
            let promptText = "繁體中文桌遊對話。請使用繁體中文回答。關鍵詞：\(currentKeywords.joined(separator: ", "))"
            
            // 🔥 [修正] 手動將文字轉為 Token
            // WhisperKit 不接受 String 類型的 prompt，必須手動 Tokenize
            var promptTokens: [Int] = []
            if let tokenizer = pipe.tokenizer {
                // 過濾掉特殊字元，只保留文字 Token
                promptTokens = tokenizer.encode(text: promptText)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }
            
            // 3. 設定解碼選項
            // language: 強制設定為中文 "zh"
            // temperature: 0.0 代表最精準，不做隨機聯想
            // promptTokens: 這是我們剛轉好的 Token 陣列
            let options = DecodingOptions(
                language: "zh",
                temperature: 0.0,
                promptTokens: promptTokens // 👈 這裡原本寫 prompt: promptText 會報錯，改用這個
            )
            
            print("📝 開始辨識 (Prompt: \(promptText.prefix(10))...)")
            
            do {
                let result = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
                let text = result.first?.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                
                print("📝 [Whisper 辨識結果]: \(text ?? "nil")")
                
                // 過濾幻覺
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
