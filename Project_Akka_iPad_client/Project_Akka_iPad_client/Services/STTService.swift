import Foundation
import AVFoundation
import WhisperKit
import Combine

@MainActor
class STTService: ObservableObject {
    @Published var isModelLoading = false
    @Published var statusMessage = "等待選擇遊戲..."
    
    private var pipe: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var audioFilename: URL?
    private var currentKeywords: [String] = []
    
    // MARK: - 模型生命週期管理
    
    func setupWhisper(keywords: [String]) async {
        self.isModelLoading = true
        self.statusMessage = "阿卡正在學習術語..."
        self.currentKeywords = keywords
        
        if pipe != nil {
            self.isModelLoading = false
            self.statusMessage = "阿卡就緒"
            return
        }
        
        do {
            // 使用 distil-large-v3 模型
            pipe = try await WhisperKit(model: "distil-large-v3", download: true)
            self.isModelLoading = false
            self.statusMessage = "阿卡就緒"
        } catch {
            self.statusMessage = "模型載入失敗: \(error.localizedDescription)"
            print("Whisper load error: \(error)")
        }
    }
    
    // MARK: - 錄音控制
    
    func startRecording() {
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
            audioRecorder?.record()
        } catch {
            print("錄音啟動失敗: \(error)")
        }
    }
    
    func stopAndTranscribe() async -> String? {
        audioRecorder?.stop()
        guard let pipe = pipe, let url = audioFilename else { return nil }
        
        // 建構 Prompt 字串
        // 格式: "繁體中文桌遊對話。關鍵詞：卡卡頌, 米寶..."
        let promptText = "繁體中文桌遊對話。關鍵詞：\(currentKeywords.joined(separator: ", "))"
        
        // [修正 1] DecodingOptions 初始化不包含 prompt 參數
        // 若您的 WhisperKit 版本支援 prompt 屬性，可嘗試: var options = DecodingOptions(...); options.prompt = ...
        let options = DecodingOptions(
            language: "zh"
            // 注意：若編譯器報錯，暫時移除 prompt 參數
            // prompt: promptText
        )
        
        // 執行辨識
        let result = try? await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        
        // [修正 2] 明確指定 CharacterSet
        let text = result?.first?.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        
        return (text?.isEmpty ?? true) ? nil : text
    }
}
