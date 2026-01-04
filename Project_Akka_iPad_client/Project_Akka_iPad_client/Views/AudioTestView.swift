import SwiftUI
import AVFoundation
import Speech
import Combine // 確保引入 Combine 以支援 ObservableObject

// MARK: - 驗證用 ViewModel
class AudioTestViewModel: ObservableObject {
    @Published var status = "準備就緒"
    @Published var recognizedText = ""
    @Published var isRecording = false
    
    // 🎤 錄音相關
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW"))
    
    // 🔊 播放相關
    // 每次播放都使用新的 Synthesizer 以避免舊實體損壞
    private var currentSynthesizer: AVSpeechSynthesizer?
    
    // MARK: - 動作 1: 開始錄音
    func startRecording() {
        // 使用 Task 確保在背景執行，並回到 MainActor 更新 UI
        Task { @MainActor in
            print("\n🎙️ ======== [動作: 開始錄音] ========")
            
            // A. 清理舊戰場
            cleanupEngine()
            
            // B. 重置 Session (先關再開，確保乾淨)
            let session = AVAudioSession.sharedInstance()
            do {
                print("   1️⃣ [Session] 準備錄音環境...")
                // 先嘗試解除鎖定 (雖不一定必要，但保險)
                try? session.setActive(false)
                
                // 設定為錄音模式
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                print("      ✅ Session Active (PlayAndRecord)")
            } catch {
                print("      ❌ Session Error: \(error)")
                self.status = "Session Error"
                return
            }
            
            // C. 建立全新引擎
            print("   2️⃣ [Engine] 建立全新 AVAudioEngine")
            let newEngine = AVAudioEngine()
            self.audioEngine = newEngine
            
            self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = self.recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true
            
            let inputNode = newEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            print("      ℹ️ Input Format: \(recordingFormat)")
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                self.recognitionRequest?.append(buffer)
            }
            
            newEngine.prepare()
            
            do {
                try newEngine.start()
                self.isRecording = true
                self.status = "正在錄音...請說話"
                self.recognizedText = ""
                print("   3️⃣ [Engine] 啟動成功 (Running)")
                
                self.recognitionTask = self.speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                    if let result = result {
                        self?.recognizedText = result.bestTranscription.formattedString
                    }
                    if let error = error {
                        print("      ⚠️ 辨識結束/錯誤: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("   ❌ Engine Start Error: \(error)")
                self.status = "Engine Start Error"
            }
        }
    }
    
    // MARK: - 動作 2: 停止並複讀 (核心修改)
    func stopAndRepeat() {
        Task { @MainActor in
            print("\n🛑 ======== [動作: 停止並複讀] ========")
            
            // 1. 徹底銷毀引擎
            print("   1️⃣ [Cleanup] 銷毀引擎...")
            if let engine = audioEngine {
                if engine.isRunning {
                    engine.stop()
                }
                engine.inputNode.removeTap(onBus: 0)
                engine.reset()
            }
            audioEngine = nil
            print("      🔥 Engine set to NIL")
            
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask?.cancel()
            recognitionTask = nil
            
            self.isRecording = false
            self.status = "處理中 (硬體釋放)..."
            
            // 🔥 [關鍵修正] 加入緩衝時間，讓硬體徹底釋放麥克風
            // 這能防止 -66748 錯誤 (Connection Invalidated)
            print("   ⏳ [Wait] 等待 0.5 秒讓硬體釋放...")
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒
            
            // 2. 切換 Session 至播放模式
            let session = AVAudioSession.sharedInstance()
            do {
                print("   2️⃣ [Session] 切換至 .playback (純播放)")
                
                // A. 先 Deactivate (掛斷電話) - 解決資源佔用
                try? session.setActive(false)
                
                // B. 設定為純播放 (這會讓系統將路由導向喇叭，並切斷麥克風連結)
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                
                print("      ✅ Session Active (.playback)")
            } catch {
                print("      ❌ Session Switch Error: \(error)")
            }
            
            self.status = "準備播放..."
            
            // 3. 播放
            let textToSpeak = self.recognizedText.isEmpty ? "沒有聽到聲音" : self.recognizedText
            self.speak(text: textToSpeak)
        }
    }
    
    private func speak(text: String) {
        print("\n🔊 ======== [動作: TTS 播放] ========")
        print("   1️⃣ [Synthesizer] 建立全新實體")
        
        // 每次都建立新的 Synthesizer，確保沒有舊的 Audio Unit 殘留
        let newSynthesizer = AVSpeechSynthesizer()
        currentSynthesizer = newSynthesizer
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-TW")
        utterance.rate = 0.5
        
        print("   2️⃣ [Speak] 呼叫 speak")
        newSynthesizer.speak(utterance)
        status = "正在播放: \(text)"
    }
    
    private func cleanupEngine() {
        print("   🧹 [Cleanup] 清理殘留引擎...")
        audioEngine?.stop()
        audioEngine = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }
}

// MARK: - 驗證用 View
struct AudioTestView: View {
    @StateObject var vm = AudioTestViewModel()
    
    var body: some View {
        VStack(spacing: 30) {
            Text("Audio Crash 驗證器")
                .font(.largeTitle)
                .bold()
                .padding(.top)
            
            // Console Log 提示
            Text("請觀察 Xcode Console 的詳細 Log")
                .font(.caption)
                .foregroundColor(.gray)
            
            Divider()
            
            Text(vm.status)
                .font(.headline)
                .foregroundColor(.blue)
                .padding()
            
            Text(vm.recognizedText.isEmpty ? "(等待語音輸入...)" : vm.recognizedText)
                .font(.title2)
                .padding()
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(10)
                .padding(.horizontal)
            
            Button(action: {
                if vm.isRecording {
                    vm.stopAndRepeat()
                } else {
                    vm.startRecording()
                }
            }) {
                VStack {
                    Image(systemName: vm.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .resizable()
                        .frame(width: 80, height: 80)
                        .foregroundColor(vm.isRecording ? .red : .blue)
                    
                    Text(vm.isRecording ? "停止並複讀" : "開始錄音")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }
            
            Spacer()
            
            Text("驗證重點：\n1. 錄音後等待 0.5s\n2. 觀察 Log 是否成功切換為 .playback\n3. 必須聽到聲音")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.bottom)
        }
    }
}
