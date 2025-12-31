import Foundation
import AVFoundation
import WhisperKit
import Combine // 🔥 必須包含這行，否則會報錯 ObservableObject

@MainActor
class STTService: ObservableObject {
    @Published var isModelLoading = true
    @Published var statusMessage = "準備載入 Whisper 模型..."
    private var pipe: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var audioFilename: URL?
    
    init() {
        setupAudioSession()
        Task {
            do {
                // 恢復使用 medium 模型，這是你之前測試成功且速度 OK 的模型
                pipe = try await WhisperKit(model: "distil-large-v3", download: true)
                isModelLoading = false
                statusMessage = "Whisper 就緒"
            } catch {
                statusMessage = "模型載入失敗"
            }
        }
    }
    
    private func setupAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // 修正 category 選項
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)
    }
    
    func startRecording() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("input.wav")
        audioFilename = url
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        audioRecorder = try? AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.record()
    }
    
    // 恢復無參數版本，確保 DecodingOptions 不會報錯
    func stopAndTranscribe() async -> String? {
        audioRecorder?.stop()
        guard let pipe = pipe, let url = audioFilename else { return nil }
        let result = try? await pipe.transcribe(audioPath: url.path, decodeOptions: DecodingOptions(language: "zh"))
        return result?.first?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
