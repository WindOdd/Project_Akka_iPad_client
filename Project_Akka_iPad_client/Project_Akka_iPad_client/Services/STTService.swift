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
    
    // MARK: - 音訊 Session 管理 (Helper Methods)
    
    // 🔥 [關鍵修改] 標記為 nonisolated，允許從背景 Task 呼叫
    nonisolated func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // 使用 .playAndRecord 並開啟 mixWithOthers，減少對系統的衝擊
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            print("🟢 Audio Session 已啟動 (Background)")
        } catch {
            print("❌ 啟動 Session 失敗: \(error.localizedDescription)")
        }
    }
    
    // 🔥 [關鍵修改] 標記為 nonisolated
    nonisolated func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("🔴 Audio Session 已釋放 (Background)")
        } catch {
            print("⚠️ 釋放 Session 失敗: \(error)")
        }
    }
    
    // MARK: - 錄音控制 (🔥 解決 UI 卡死的核心)
    
    // 1. 改為 async，讓 UI 執行緒可以繼續刷新
    func startRecording() async {
        print("🎙️ 準備啟動錄音流程...")
        
        // 2. 將「耗時 3~5秒」的硬體初始化工作丟到背景執行緒 (Detached Task)
        let recorder = await Task.detached(priority: .userInitiated) { [weak self] () -> AVAudioRecorder? in
            guard let self = self else { return nil }
            
            // A. 這裡執行最耗時的 Session 啟動 (原本卡死 UI 的兇手)
            self.activateAudioSession()
            
            // B. 準備路徑與設定
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("input.wav")
            
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            // C. 初始化 Recorder
            do {
                let newRecorder = try AVAudioRecorder(url: url, settings: settings)
                // 這裡只做初始化，不呼叫 record()，因為 record() 最好回主線程呼叫比較保險
                return newRecorder
            } catch {
                print("❌ 錄音初始化失敗: \(error)")
                return nil
            }
        }.value
        
        // 3. 回到 Main Actor (主執行緒) 更新狀態並開始錄音
        if let validRecorder = recorder {
            self.audioRecorder = validRecorder
            self.audioFilename = validRecorder.url
            
            let success = validRecorder.record()
            if success {
                print("🎙️ 錄音正式開始 (UI 應已更新)")
            } else {
                print("❌ record() 回傳失敗")
                self.statusMessage = "無法啟動錄音"
            }
        } else {
            self.statusMessage = "錄音啟動失敗"
        }
    }
    
    func stopAndTranscribe() async -> String? {
        audioRecorder?.stop()
        print("⏹️ 停止錄音")
        
        // 4. 錄音結束後釋放資源 (背景執行，避免卡頓)
        Task.detached {
            self.deactivateAudioSession()
        }
        
        guard let pipe = pipe, let url = audioFilename else { return nil }
        
        // 檔案檢查 (防崩潰)
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                print("⚠️ [STT] 錄音檔不存在")
                return nil
            }
            
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = attr[.size] as? UInt64 ?? 0
            if fileSize < 4096 { // 小於 4KB 視為無效
                print("⚠️ [STT] 錄音檔太短 (\(fileSize) bytes)，跳過辨識")
                return nil
            }
        } catch {
            print("⚠️ [STT] 檔案檢查失敗: \(error)")
            return nil
        }
        
        let promptText = "繁體中文桌遊對話。關鍵詞：\(currentKeywords.joined(separator: ", "))"
        
        // DecodingOptions
        let options = DecodingOptions(language: "zh")
        
        let result = try? await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let text = result?.first?.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        // 🔥 [Debug] 印出辨識結果
        print("📝 [Whisper 辨識結果]: \(text ?? "nil (無聲)")")
        
        return (text?.isEmpty ?? true) ? nil : text
    }
}
