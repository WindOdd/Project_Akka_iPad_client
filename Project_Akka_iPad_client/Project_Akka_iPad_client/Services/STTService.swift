import Foundation
import AVFoundation
import WhisperKit
import Combine

// MARK: - 模型定義
enum WhisperModel: String, CaseIterable, Identifiable {
    case distilLargeV3 = "distil-large-v3"
    case largeV3 = "large-v3"
    case medium = "medium"
    case base = "base"
    case small = "small"
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .distilLargeV3: return "Distil Large V3 (推薦)"
        case .largeV3: return "Large V3 (精準/慢)"
        case .medium: return "Medium (平衡)"
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
        return .distilLargeV3
    }()
    
    // MARK: - Internal Properties
    private var pipe: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var audioFilename: URL?
    private var currentKeywords: [String] = []
    
    // MARK: - 模型生命週期管理
    
    func setupWhisper(keywords: [String]) async {
        self.currentKeywords = keywords
        
        // 🔥 [新增] 預先啟動 Always-On Session，確保 App 一開始就佔用音訊通道
        await configureAlwaysOnSession()
        if pipe != nil {
            print("✅ 模型實體已存在，僅更新關鍵字")
            return
        }
        
        self.isModelLoading = true
        self.statusMessage = "下載模型: \(currentModel.rawValue)..."
        
        do {
            print("🚀 開始載入模型: \(currentModel.rawValue)")
            pipe = try await WhisperKit(model: currentModel.rawValue, download: true)
            self.isModelLoading = false
            self.statusMessage = "阿卡就緒 (\(currentModel.rawValue))"
            print("✅ 模型載入完成")
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
    
    // MARK: - Audio Session Management (核心修改區)
        
        /// 🔥 [修改] 配置常駐型 Session
        /// 策略：設定為 PlayAndRecord + DefaultToSpeaker，同時滿足錄音與 TTS 擴音需求
        nonisolated func configureAlwaysOnSession() async {
            do {
                let session = AVAudioSession.sharedInstance()
                // 關鍵：DefaultToSpeaker 確保 TTS 不會從聽筒出來
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                print("✅ [Audio] Session 設定為 Always-On PlayAndRecord")
            } catch {
                print("❌ [Audio] Session 設定失敗: \(error)")
            }
        }

        /// 🔥 [修改] 停用功能改為空實作
        /// 策略：永遠不關閉 Session，避免硬體重啟導致的 Crash
        nonisolated func deactivateSession() async {
            // No-op: 保持 Session 開啟
            print("🛡️ [Audio] 忽略停用請求 (Always-On Strategy)")
        }
    
    
    // MARK: - Recording Logic
    
    func startRecording() async {
        print("🎙️ 準備啟動錄音流程...")
        
        // 🔧 [修正] 直接在背景執行 async 函數，不再使用 detached task 以避免 actor isolation 問題
        // 1. 啟動 Session (async)
        await configureAlwaysOnSession()
        
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
        
        // 🔥🔥 [關鍵修正 1] 徹底銷毀 Recorder
        // 這是為了解除 AVAudioRecorder 對 AudioEngine 16kHz 的硬體佔用
        audioRecorder = nil
        print("⏹️ 錄音機實例已銷毀")
        
        guard let pipe = pipe, let url = audioFilename else { return nil }
        
        // 檔案檢查 (防崩潰)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                print("⚠️ [STT] 錄音檔不存在")
                return nil
            }
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attr[.size] as? UInt64 ?? 0
            if fileSize < 4096 {
                print("⚠️ [STT] 錄音檔太短 (\(fileSize) bytes)，跳過辨識")
                return nil
            }
        } catch {
            print("⚠️ [STT] 檔案檢查失敗: \(error)")
            return nil
        }
        
        // 3. 執行辨識
        let promptText = "繁體中文桌遊對話。關鍵詞：\(currentKeywords.joined(separator: ", "))"
        // 若 WhisperKit 版本支援 initialPrompt，可加入 promptText
        let options = DecodingOptions(language: "zh")
        
        let result = try? await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let text = result?.first?.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        print("📝 [Whisper 辨識結果]: \(text ?? "nil (無聲)")")
        
        return (text?.isEmpty ?? true) ? nil : text
    }
}
