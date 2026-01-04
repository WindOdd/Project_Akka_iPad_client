import Foundation
import AVFoundation
import Speech  // 👈 引入 Apple 語音框架
import WhisperKit
import Combine

// MARK: - 模型定義 (雙引擎整合)
enum WhisperModel: String, CaseIterable, Identifiable {
    // 🍎 Apple 內建
    case native = "native_apple"
    
    // 🤖 OpenAI Whisper 系列
    case base = "base"                                      // User 指定測試
    case openaiLargeV3Turbo_626MB = "openai_whisper-large-v3-v20240930_626MB" // 原本的 Turbo
    
    var id: String { self.rawValue }
    
    var displayName: String {
        switch self {
        case .native: return "Apple 內建聽寫 (極速 ⚡️)"
        case .base: return "Whisper Base (平衡 ⚖️)"
        case .openaiLargeV3Turbo_626MB: return "Turbo (精準/慢 🐢)"
        }
    }
    
    // 判斷是否為 Apple 引擎
    var isNative: Bool { return self == .native }
}

@MainActor
class STTService: ObservableObject {
    // MARK: - Published States
    @Published var isModelLoading = false
    @Published var statusMessage = "等待選擇遊戲..."
    
    @Published var currentModel: WhisperModel = .native // 預設先用 Native (最快)
    
    // MARK: - Whisper 引擎變數
    private var pipe: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var audioFilename: URL?
    private var currentKeywords: [String] = []
    
    // MARK: - Apple Native 引擎變數
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var nativeLastTranscription: String?
    // 👇 [新增] 用來暫存等待中的 Continuation
    private var recognitionContinuation: CheckedContinuation<String?, Never>?
    // MARK: - 模型切換與設定
    
    func setupWhisper(keywords: [String]) async {
        self.currentKeywords = keywords
        
        if currentModel.isNative {
            // A. Apple Native 模式
            print("🍎 切換至 Apple Native 引擎")
            // 釋放 Whisper 記憶體
            pipe = nil
            
            SFSpeechRecognizer.requestAuthorization { authStatus in
                DispatchQueue.main.async {
                    switch authStatus {
                    case .authorized:
                        self.statusMessage = "Apple 聽寫就緒"
                    default:
                        self.statusMessage = "無聽寫權限"
                    }
                }
            }
            
        } else {
            // B. WhisperKit 模式
            print("🤖 切換至 Whisper 引擎: \(currentModel.rawValue)")
            
            // 如果已經載入同款模型，就跳過
            if pipe != nil && pipe?.modelState == .loaded {
                 // 這裡簡化判斷，實際可更嚴謹
                 // 若想強制切換 Base/Turbo，建議還是重新 load
            }
            
            self.isModelLoading = true
            self.statusMessage = "載入模型: \(currentModel.displayName)..."
            
            do {
                // 釋放舊模型
                pipe = nil
                
                // 下載並載入新模型
                pipe = try await WhisperKit(model: currentModel.rawValue, download: true)
                
                // Warmup
                self.statusMessage = "正在熱身..."
                try? await pipe?.transcribe(audioArray: [Float](repeating: 0, count: 16000))
                
                self.isModelLoading = false
                self.statusMessage = "Whisper 就緒"
                print("✅ Whisper 模型載入完成")
            } catch {
                self.statusMessage = "載入失敗: \(error.localizedDescription)"
                print("❌ Whisper Error: \(error)")
                self.isModelLoading = false
            }
        }
    }
    
    func switchModel(to newModel: WhisperModel) {
        if newModel == currentModel { return }
        print("🔄 切換模型至: \(newModel.rawValue)")
        currentModel = newModel
        UserDefaults.standard.set(newModel.rawValue, forKey: "selected_whisper_model")
        
        // 這裡不需立即 resetModel，因為 MainViewModel 會呼叫 reloadModel 或 setupWhisper
        // 但為了保險，先清空狀態
        resetModel()
    }
    
    func resetModel() {
        // 清空所有引擎狀態
        pipe = nil
        stopNativeAudioEngine()
        audioRecorder?.stop()
        audioRecorder = nil
        print("🗑 所有引擎記憶體已釋放")
    }
    
    // MARK: - 錄音入口 (自動分流)
    
    func startRecording() async {
        if currentModel.isNative {
            await startNativeRecording()
        } else {
            await startWhisperRecording()
        }
    }
    
    func stopAndTranscribe() async -> String? {
        if currentModel.isNative {
            return await stopNativeRecordingAndGetResult()
        } else {
            return await stopWhisperRecordingAndTranscribe()
        }
    }
    
    // MARK: - 引擎 A: Apple Native 實作
    
    private func startNativeRecording() async {
        let session = AVAudioSession.sharedInstance()
        do {
            // 🔥 [修改] 直接切換 Mode 為 measurement (適合語音辨識)，保持 Active
            // 移除 setActive(false) 以避免硬體重啟延遲
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            } catch {
                print("⚠️ [STT] Session 設定失敗: \(error)")
            }
        
        // 2. 準備 Request
        stopNativeAudioEngine() // 確保乾淨
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true
        
        // 3. 設定 Input Node
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }
        
        // 4. 開始
        audioEngine.prepare()
        do {
            try audioEngine.start()
            self.statusMessage = "正在聆聽 (Native)..."
            
            // 啟動 Task
            // 👇 [修改] 這裡的閉包內容要更新
                    recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                        guard let self = self else { return }
                        
                        if let result = result {
                            // 1. 實時更新文字
                            self.nativeLastTranscription = result.bestTranscription.formattedString
                            
                            // 2. ✅ [新增] 如果是最終結果 (isFinal)，就喚醒等待中的 Continuation
                            if result.isFinal {
                                self.recognitionContinuation?.resume(returning: self.nativeLastTranscription)
                                self.recognitionContinuation = nil
                            }
                        }
                        
                        if let error = error {
                            self.stopNativeAudioEngine()
                            
                            // 3. ✅ [新增] 如果發生錯誤，也要喚醒 Continuation (回傳目前的結果或 nil)
                            // 這樣 stopNativeRecordingAndGetResult 就不會一直卡住
                            self.recognitionContinuation?.resume(returning: self.nativeLastTranscription)
                            self.recognitionContinuation = nil
                        }
                    }
                    print("🎙️ [Native] 開始錄音")
                } catch {
                    print("❌ [Native] 啟動失敗: \(error)")
                }
            }
    
    private func stopNativeAudioEngine() {
        if audioEngine.isRunning {
           audioEngine.stop()
           audioEngine.inputNode.removeTap(onBus: 0)
        // 🔥 [新增] 強制重置引擎，釋放硬體資源，解決 TTS -66748 錯誤
            audioEngine.reset()
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        // recognitionTask 不 cancel，保留結果
     }
    
    private func stopNativeRecordingAndGetResult() async -> String? {
        // 1. 告訴系統錄音資料結束了，這會觸發 recognitionTask 進行最後處理並回傳 isFinal
        recognitionRequest?.endAudio()
        
        // ❌ [移除] 舊的寫法：不穩定的等待
        // stopNativeAudioEngine()
        // try? await Task.sleep(nanoseconds: 200_000_000)
        // let text = nativeLastTranscription
        // ...
        
        // ✅ [新寫法] 使用 Continuation 安全等待結果
        let finalResult: String? = await withCheckedContinuation { continuation in
            // 儲存這個 continuation，讓 startNativeRecording 裡的閉包可以呼叫它
            self.recognitionContinuation = continuation
            
            // ⚠️ [安全機制] 設定一個 2 秒的 Timeout
            // 萬一 Apple 的 API 沒有回傳 isFinal 也不報錯，我們不能讓 App 卡死
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2秒
                if self.recognitionContinuation != nil {
                    print("⚠️ [Native] 等待結果逾時，強制回傳目前結果")
                    self.recognitionContinuation?.resume(returning: self.nativeLastTranscription)
                    self.recognitionContinuation = nil
                }
            }
        }
        
        // 2. 確保 Audio Engine 關閉
        stopNativeAudioEngine()
        
        // 3. 重置狀態
        nativeLastTranscription = nil
        recognitionTask = nil
        
        print("🍎 [Native 最終結果]: \(finalResult ?? "nil")")
        return (finalResult?.isEmpty ?? true) ? nil : finalResult
    }
    
    // MARK: - 引擎 B: WhisperKit 實作
    
    private func startWhisperRecording() async {
        print("🎙️ [Whisper] 準備錄音...")
        
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        // Whisper 比較適合 videoRecording 模式 (Raw Audio)
        try? session.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
        
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper_input.wav")
        self.audioFilename = url
        
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            print("🎙️ [Whisper] 錄音開始")
        } catch {
            print("❌ [Whisper] 錄音失敗: \(error)")
        }
    }
    
    private func stopWhisperRecordingAndTranscribe() async -> String? {
        // 1. 停止
        audioRecorder?.stop()
        audioRecorder = nil
        
        guard let pipe = pipe, let url = audioFilename else { return nil }
        
        // 2. 檢查檔案
        if !FileManager.default.fileExists(atPath: url.path) { return nil }
        
        // 3. Prompt
        // 這裡將 Native 選擇的 keywords 轉為 Prompt
        let promptText = "繁體中文桌遊對話。關鍵詞：\(currentKeywords.joined(separator: ", "))"
        
        // Encode prompt tokens (簡化版)
        let promptTokens = pipe.tokenizer?.encode(text: promptText).filter { $0 < (pipe.tokenizer?.specialTokens.specialTokenBegin ?? 50257) }
        
        // 4. Decode Options
        // 您要求的 Base 測試：使用較正常的參數
        let options = DecodingOptions(
            language: "zh",
            temperature: 0.0,
            promptTokens: promptTokens, // Prompt 放在這
            compressionRatioThreshold: 2.4,
            logProbThreshold: -2.0,     // 不再使用 -100，改回正常值
            noSpeechThreshold: 0.4      // 降低門檻
        )
        
        print("📝 [Whisper] 開始推論...")
        self.statusMessage = "Whisper 思考中..."
        
        do {
            let result = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
            let text = result.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("🤖 [Whisper 結果]: \(text ?? "nil")")
            return (text?.isEmpty ?? true) ? nil : text
        } catch {
            print("❌ [Whisper] 推論失敗: \(error)")
            return nil
        }
    }
}
