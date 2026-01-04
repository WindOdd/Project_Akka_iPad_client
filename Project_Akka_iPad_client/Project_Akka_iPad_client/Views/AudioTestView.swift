import SwiftUI
import Speech
import AVFoundation
import Combine
// MARK: - 驗證用 ViewModel (最終核彈級修復：強制重建 Synthesizer)
class AudioTestViewModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var recognizedText = ""
    @Published var isRecording = false
    @Published var statusMessage = "準備就緒"
    
    // 核心元件
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    // 🔥 關鍵 1: 兩個都必須是 var，因為都要重建
    // audioEngine: 錄音結束後重建，確保 Input Node 乾淨
    // speechSynthesizer: 播放前重建，確保拿到新的 Connection ID (解決 -66748)
    private var audioEngine = AVAudioEngine()
    private var speechSynthesizer = AVSpeechSynthesizer()
    
    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }
    
    // MARK: - 錄音功能
    
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    func startRecording() {
        // 1. 確保 TTS 閉嘴
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        
        // 2. 清理舊任務
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        // 3. 設定 Session (.record 模式)
        // 使用 .record 模式是最單純的，它告訴系統「我現在只要麥克風」
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "Session 設定失敗: \(error.localizedDescription)"
            return
        }
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            statusMessage = "無法建立 Request"
            return
        }
        recognitionRequest.shouldReportPartialResults = true
        
        // 4. 設定 Input
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // 5. 建立 Task
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
            
            // 🔥 結束或錯誤處理邏輯
            if error != nil || isFinal {
                // A. 停止引擎
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)
                
                // B. 重建引擎 (確保下一次錄音是全新的狀態)
                self.audioEngine.reset()
                self.audioEngine = AVAudioEngine()
                print("✅ [Audio] 引擎已重建")
                
                self.recognitionRequest = nil
                self.recognitionTask = nil
                
                let finalText = self.recognizedText
                
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.statusMessage = "錄音結束"
                    
                    // C. 關閉 Session (掛斷電話)
                    // 這一步會切斷所有音訊連線，導致舊的 TTS 實體失效
                    let session = AVAudioSession.sharedInstance()
                    do {
                        try session.setActive(false, options: .notifyOthersOnDeactivation)
                        print("✅ [Audio] Session 已停用 (setActive: false)")
                    } catch {
                        print("⚠️ [Audio] 停用失敗: \(error)")
                    }
                    
                    // D. 延遲後播放
                    // 給系統 1.0 秒的時間釋放麥克風鎖定
                    print("⏳ [Wait] 等待 1.0 秒...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if !finalText.isEmpty {
                            self.speakText()
                        } else {
                            self.statusMessage = "沒有聽到聲音"
                        }
                    }
                }
            }
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
            statusMessage = "正在錄音..."
            print("✅ [Audio] 錄音開始")
        } catch {
            statusMessage = "引擎啟動失敗"
        }
    }
    
    func stopRecording() {
        print("🛑 [User] 停止錄音")
        // 這會觸發上面的 recognitionTask 閉包，執行清理與播放流程
        recognitionRequest?.endAudio()
        statusMessage = "處理中..."
    }
    
    // MARK: - 朗讀功能 (核彈級修復)
    
    func speakText() {
        print("========== 開始朗讀流程 ==========")
        
        // 1. 設定 Session 為 .playback
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(true, options: [])
            print("✅ [Audio] Session 設定為 .playback")
        } catch {
            print("❌ [Audio] 設定失敗: \(error)")
            statusMessage = "音訊錯誤"
            return
        }
        
        // 2. 🔥 [唯一解法] 強制建立新的 Synthesizer
        // 因為舊的實體在 Session 斷開後已經失效，必須換新的才能拿到新的 Connection ID
        print("🔄 [TTS] 重建 AVSpeechSynthesizer...")
        speechSynthesizer = AVSpeechSynthesizer()
        speechSynthesizer.delegate = self
        
        // 3. 播放
        let utterance = AVSpeechUtterance(string: recognizedText)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.5
        
        print("🔊 [TTS] 呼叫 speak: \(recognizedText)")
        statusMessage = "正在朗讀..."
        speechSynthesizer.speak(utterance)
    }
    
    // MARK: - Delegate
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("✅ [TTS] 朗讀完成")
        DispatchQueue.main.async {
            self.statusMessage = "朗讀完成"
        }
    }
}

// MARK: - View
struct AudioTestView: View {
    @StateObject private var vm = AudioTestViewModel()
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Audio Crash 驗證器 (最終版)")
                .font(.largeTitle)
                .bold()
                .padding(.top)
            
            Text(vm.statusMessage)
                .font(.headline)
                .foregroundColor(.gray)
            
            ScrollView {
                Text(vm.recognizedText.isEmpty ? "..." : vm.recognizedText)
                    .font(.title2)
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 150)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            .padding(.horizontal)
            
            Button(action: {
                vm.toggleRecording()
            }) {
                VStack {
                    Image(systemName: vm.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .resizable()
                        .frame(width: 80, height: 80)
                        .foregroundColor(vm.isRecording ? .red : .blue)
                    Text(vm.isRecording ? "停止錄音" : "開始錄音")
                }
            }
            
            Spacer()
            
            Text("策略：強制重建 Synthesizer\n解決 -66748 與 mDataByteSize 0")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom)
        }
    }
}
