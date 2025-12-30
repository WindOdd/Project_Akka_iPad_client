// Services/STTService.swift
import Foundation
import SwiftUI
import Combine
import AVFoundation
import WhisperKit

@MainActor
class STTService: ObservableObject {
    @Published var isModelLoading = true
    @Published var statusMessage = "準備載入 AI 模型..."
    
    private var pipe: WhisperKit?
    private var audioRecorder: AVAudioRecorder?
    private var audioFilename: URL?
    
    init() {
        setupAudioSession()
        Task {
            do {
                self.statusMessage = "下載 Whisper 模型中..."
                // 下載並載入 Base 模型
                pipe = try await WhisperKit(model: "distil-large-v3", download: true)
                self.isModelLoading = false
                self.statusMessage = "Whisper 模型就緒"
                print("✅ Whisper 模型載入成功")
            } catch {
                print("❌ 模型載入失敗: \(error)")
                self.statusMessage = "模型載入失敗"
            }
        }
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // 修正黃色警告：使用完整寫法
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("❌ Audio Session 設定失敗: \(error)")
        }
    }
    
    func startRecording() {
        let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        audioFilename = docPath.appendingPathComponent("akka_input.wav")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename!, settings: settings)
            audioRecorder?.record()
            print("🎙️ 開始錄音...")
        } catch {
            print("❌ 錄音啟動失敗: \(error)")
        }
    }
    
    // 移除 Prompt 參數，回歸單純辨識
    func stopAndTranscribe() async -> String? {
        audioRecorder?.stop()
        audioRecorder = nil
        
        guard let pipe = pipe, let audioURL = audioFilename else {
            print("⚠️ 模型未就緒或無音檔")
            return nil
        }
        
        print("🧠 開始辨識 (Whisper On-Device)...")
        
        do {
            // 使用最基本的解碼選項 (暫時移除 Prompt Injection)
            let options = DecodingOptions(language: "zh")
            
            let result = try await pipe.transcribe(
                audioPath: audioURL.path,
                decodeOptions: options
            )
            
            let text = result.first?.text ?? ""
            print("📝 辨識結果: \(text)")
            
            // 修正紅字：明確使用 CharacterSet
            return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
        } catch {
            print("❌ 辨識失敗: \(error)")
            return nil
        }
    }
}
