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
    
    // MARK: - 音訊 Session 管理 (🔥 核心修改：脈衝策略)
    
    // 1. 啟動 Session (錄音或朗讀前呼叫)
    func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // 關鍵：加入 .mixWithOthers 減少衝突
            // 保持 .playAndRecord 避免切換 category 造成 crash
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("🟢 Audio Session 已啟動 (Active)")
        } catch {
            print("❌ 啟動 Session 失敗: \(error.localizedDescription)")
            statusMessage = "音訊裝置錯誤"
        }
    }
    
    // 2. 關閉 Session (錄音結束後呼叫，釋放資源給 TTS)
    func deactivateAudioSession() {
        do {
            // notifyOthersOnDeactivation: 讓其他 App (或我們自己的 TTS) 知道現在可以用喇叭了
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("🔴 Audio Session 已釋放 (Inactive)")
        } catch {
            print("⚠️ 釋放 Session 失敗: \(error)")
        }
    }
    
    // MARK: - 錄音控制
    
    func startRecording() {
        // 1. 錄音前：佔用資源
        activateAudioSession()
        
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("input.wav")
        audioFilename = url
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            let success = audioRecorder?.record() ?? false
            if success {
                print("🎙️ 開始錄音...")
            } else {
                print("❌ 錄音啟動失敗 (record 回傳 false)")
                statusMessage = "無法啟動錄音"
            }
        } catch {
            print("❌ 錄音例外錯誤: \(error)")
            statusMessage = "錄音錯誤"
        }
    }
    
    func stopAndTranscribe() async -> String? {
        audioRecorder?.stop()
        print("⏹️ 停止錄音")
        
        // 2. 錄音後：🔥 立即釋放資源 (解決 IPCAUClient 鎖死問題)
        deactivateAudioSession()
        
        guard let pipe = pipe, let url = audioFilename else { return nil }
        
        // 檔案檢查
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? UInt64, size < 100 {
                print("⚠️ 錄音檔案過小 (\(size) bytes)")
                return nil
            }
        } catch {
            return nil
        }
        
        let promptText = "繁體中文桌遊對話。關鍵詞：\(currentKeywords.joined(separator: ", "))"
        
        // DecodingOptions
        let options = DecodingOptions(language: "zh")
        
        let result = try? await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let text = result?.first?.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        return (text?.isEmpty ?? true) ? nil : text
    }
}
