import SwiftUI
import Speech
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var voiceManager = VoiceManager()
    
    var body: some View {
        VStack(spacing: 30) {
            Text("語音辨識與朗讀")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            // 錄音按鈕
            Button(action: {
                voiceManager.toggleRecording()
            }) {
                VStack {
                    Image(systemName: voiceManager.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .resizable()
                        .frame(width: 80, height: 80)
                        .foregroundColor(voiceManager.isRecording ? .red : .blue)
                    
                    Text(voiceManager.isRecording ? "停止錄音" : "開始錄音")
                        .font(.headline)
                        .padding(.top, 8)
                }
            }
            .padding()
            
            // 狀態顯示
            Text(voiceManager.statusMessage)
                .font(.subheadline)
                .foregroundColor(.gray)
                .padding(.horizontal)
            
            // 辨識結果顯示
            ScrollView {
                Text(voiceManager.recognizedText.isEmpty ? "辨識結果會顯示在這裡..." : voiceManager.recognizedText)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
            }
            .frame(maxHeight: 300)
            .padding(.horizontal)
            
            // 朗讀按鈕
            Button(action: {
                voiceManager.speakText()
            }) {
                HStack {
                    Image(systemName: "speaker.wave.2.fill")
                    Text("朗讀文字")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding()
                .background(voiceManager.recognizedText.isEmpty ? Color.gray : Color.green)
                .cornerRadius(10)
            }
            .disabled(voiceManager.recognizedText.isEmpty)
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
        .onAppear {
            voiceManager.requestPermissions()
        }
    }
}

class VoiceManager: NSObject, ObservableObject {
    @Published var recognizedText = ""
    @Published var isRecording = false
    @Published var statusMessage = "準備就緒"
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }
    
    // 請求權限
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self.statusMessage = "已授權語音辨識"
                case .denied:
                    self.statusMessage = "語音辨識權限被拒絕"
                case .restricted:
                    self.statusMessage = "語音辨識受限"
                case .notDetermined:
                    self.statusMessage = "尚未決定語音辨識權限"
                @unknown default:
                    self.statusMessage = "未知的授權狀態"
                }
            }
        }
        
        AVAudioSession.sharedInstance().requestRecordPermission { allowed in
            DispatchQueue.main.async {
                if !allowed {
                    self.statusMessage = "麥克風權限被拒絕"
                }
            }
        }
    }
    
    // 切換錄音狀態
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    // 開始錄音
    func startRecording() {
        // 重置之前的任務
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        // 配置音訊會話
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "音訊會話設定失敗"
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        let inputNode = audioEngine.inputNode
        guard let recognitionRequest = recognitionRequest else {
            statusMessage = "無法建立辨識請求"
            return
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            var isFinal = false
            
            if let result = result {
                DispatchQueue.main.async {
                    self.recognizedText = result.bestTranscription.formattedString
                    print("辨識中：\(self.recognizedText)")
                }
                isFinal = result.isFinal
            }
            
            if error != nil || isFinal {
                self.audioEngine.stop()
                    inputNode.removeTap(onBus: 0)
                    
                    // 完全銷毀並重新建立音訊引擎
                    self.audioEngine.reset()
                    self.audioEngine = AVAudioEngine()
                    print("音訊引擎已完全重建")
                    
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                
                // 保存最終辨識結果
                let finalText = self.recognizedText
                
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.statusMessage = "錄音結束"
                    print("最終辨識結果：\(finalText)")
                    
                    // 停用錄音音訊會話
                    let audioSession = AVAudioSession.sharedInstance()
                    do {
                        try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                    } catch {
                        print("停用音訊會話失敗：\(error.localizedDescription)")
                    }
                    
                    // 延遲 1 秒後自動播放
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if !finalText.isEmpty {
                            self.speakText()
                        } else {
                            self.statusMessage = "沒有辨識到文字"
                        }
                    }
                }
            }
        }
        
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
            isRecording = true
            statusMessage = "正在錄音..."
        } catch {
            statusMessage = "音訊引擎啟動失敗"
        }
    }
    
    // 停止錄音
    func stopRecording() {
        recognitionRequest?.endAudio()
        statusMessage = "處理中..."
    }
    
    // 朗讀文字
    // 朗讀文字
    func speakText() {
        print("========== 開始朗讀流程 ==========")
        print("1. 要朗讀的文字：\(recognizedText)")
        print("2. 文字長度：\(recognizedText.count)")
        
        // 檢查 audioEngine 狀態
        print("3. audioEngine.isRunning: \(audioEngine.isRunning)")
        
        // 檢查 speechSynthesizer 狀態
        print("4. speechSynthesizer.isSpeaking: \(speechSynthesizer.isSpeaking)")
        print("5. speechSynthesizer.isPaused: \(speechSynthesizer.isPaused)")
        
        // 獲取當前音訊會話狀態
        let audioSession = AVAudioSession.sharedInstance()
        print("6. 當前音訊會話類別: \(audioSession.category.rawValue)")
        print("7. 當前音訊會話模式: \(audioSession.mode.rawValue)")
        print("8. 音訊會話是否啟用: \(audioSession.isOtherAudioPlaying)")
        
        // 重新設定音訊會話為播放模式
        do {
            print("9. 準備設定音訊會話為播放模式...")
            try audioSession.setCategory(.playback, mode: .default, options: [])
            print("10. 音訊會話類別設定成功")
            
            try audioSession.setActive(true, options: [])
            print("11. 音訊會話啟用成功")
            
            // 再次檢查狀態
            print("12. 設定後音訊會話類別: \(audioSession.category.rawValue)")
            print("13. 設定後音訊會話是否啟用: \(audioSession.isOtherAudioPlaying)")
            
        } catch let error as NSError {
            print("❌ 音訊會話設定失敗")
            print("錯誤代碼: \(error.code)")
            print("錯誤描述: \(error.localizedDescription)")
            print("錯誤資訊: \(error.userInfo)")
            statusMessage = "音訊設定失敗: \(error.localizedDescription)"
            return
        }
        
        if speechSynthesizer.isSpeaking {
            print("14. 停止現有的朗讀...")
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        
        // 建立語音內容
        let utterance = AVSpeechUtterance(string: recognizedText)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        print("15. AVSpeechUtterance 建立成功")
        print("16. 語音語言: \(utterance.voice?.language ?? "nil")")
        print("17. 語音速度: \(utterance.rate)")
        print("18. 語音音量: \(utterance.volume)")
        
        // 檢查可用的語音
        let availableVoices = AVSpeechSynthesisVoice.speechVoices()
        let zhVoices = availableVoices.filter { $0.language.hasPrefix("zh") }
        print("19. 系統可用的中文語音數量: \(zhVoices.count)")
        for (index, voice) in zhVoices.enumerated() {
            print("    語音 \(index): \(voice.language) - \(voice.name)")
        }
        
        print("20. 準備呼叫 speechSynthesizer.speak()...")
        statusMessage = "正在朗讀..."
        
        speechSynthesizer.speak(utterance)
        
        print("21. speechSynthesizer.speak() 已呼叫")
        print("22. 呼叫後 isSpeaking: \(speechSynthesizer.isSpeaking)")
        print("========== 朗讀流程結束 ==========\n")
    }
}

extension VoiceManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        print("🎤 朗讀已開始")
        DispatchQueue.main.async {
            self.statusMessage = "正在朗讀..."
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("✅ 朗讀已完成")
        DispatchQueue.main.async {
            self.statusMessage = "朗讀完成"
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        print("⏸️ 朗讀已暫停")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        print("▶️ 朗讀已繼續")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("❌ 朗讀已取消")
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        print("📝 正在朗讀字元範圍: \(characterRange)")
    }
}

#Preview {
    ContentView()
}
