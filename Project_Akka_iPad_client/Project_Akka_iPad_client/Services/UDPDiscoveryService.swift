import Foundation
import Network
import Combine
import Darwin

let UDP_PORT: UInt16 = 37020
let MAGIC_STRING = "DISCOVER_AKKA_SERVER"

class UDPDiscoveryService: ObservableObject {
    // MARK: - Published States
    @Published var serverIP: String?
    @Published var isConnected: Bool = false
    @Published var statusMessage: String = "準備連線..."
    @Published var isScanning: Bool = false
    
    // MARK: - Internal Properties
    private var socketFD: Int32 = -1
    private let dispatchQueue = DispatchQueue(label: "com.akka.udp.bsd", qos: .userInitiated)
    
    // 參數設定
    private let maxRetriesPerCycle = 6     // 每次連發 6 下
    private let maxCycles = 10             // 最多試 10 輪
    private let cooldownSeconds = 30.0     // 失敗後休息 30 秒
    
    // 計數器
    private var currentRetry = 0
    private var currentCycle = 0
    
    // 用於取消延遲任務的 WorkItem (取代 Timer)
    private var pendingTask: DispatchWorkItem?
    
    // MARK: - Public Methods
    
    func startDiscovery() {
        stopDiscovery() // 重置狀態
        
        print("🚀 啟動智慧 UDP 搜尋 (Random Jitter + Backoff)...")
        
        self.isConnected = false
        self.isScanning = true
        self.currentCycle = 0
        self.currentRetry = 0
        self.statusMessage = "正在呼叫阿卡主機..."
        
        if setupSocket() {
            startReceivingLoop()
            // 啟動廣播排程
            scheduleNextBroadcast(delay: 0.1)
        } else {
            self.isScanning = false
            self.statusMessage = "Socket 初始化失敗"
        }
    }
    
    func stopDiscovery() {
        // 取消待執行的任務
        pendingTask?.cancel()
        pendingTask = nil
        
        isScanning = false
        
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }
    
    // MARK: - Logic Core (Recursive Loop)
    
    private func scheduleNextBroadcast(delay: TimeInterval) {
        // 建立新的任務
        let task = DispatchWorkItem { [weak self] in
            self?.performBroadcastStep()
        }
        self.pendingTask = task
        
        // 排程執行
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    
    private func performBroadcastStep() {
        // 若已連線或被停止，直接退出
        guard isScanning && !isConnected else { return }
        
        // 檢查是否完成一輪 (6次)
        if currentRetry >= maxRetriesPerCycle {
            // 進入下一輪判定
            handleCycleCompletion()
            return
        }
        
        // --- 執行廣播 ---
        currentRetry += 1
        _ = (currentCycle * maxRetriesPerCycle) + currentRetry
        
        // 更新 UI (顯示輪數與次數)
        self.statusMessage = "搜尋中 (輪次 \(currentCycle + 1)/\(maxCycles) - 次數 \(currentRetry)/\(maxRetriesPerCycle))..."
        
        sendBroadcast()
        
        // --- 排程下一次 (隨機間隔 1~3 秒) ---
        // 目的：避免多台 iPad 同時重開機造成封包碰撞
        let randomInterval = Double.random(in: 1.0...3.0)
        scheduleNextBroadcast(delay: randomInterval)
    }
    
    private func handleCycleCompletion() {
        currentCycle += 1
        
        // 檢查是否超過總輪數 (10輪)
        if currentCycle >= maxCycles {
            print("⚠️ UDP 搜尋徹底失敗 (10輪結束)")
            stopDiscovery()
            self.statusMessage = "找不到主機，請手動設定 IP"
            return
        }
        
        // --- 進入冷卻期 (30秒) ---
        print("⏳ 第 \(currentCycle) 輪搜尋結束，冷卻 \(Int(cooldownSeconds)) 秒...")
        self.statusMessage = "暫無回應，\(Int(cooldownSeconds)) 秒後重試..."
        
        // 重置當前輪的嘗試次數
        currentRetry = 0
        
        // 排程 30 秒後開始下一輪
        scheduleNextBroadcast(delay: cooldownSeconds)
    }
    
    // MARK: - Low Level Socket Operations
    
    private func setupSocket() -> Bool {
        socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { return false }
        
        var broadcastEnable = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int>.size))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = CFSwapInt32HostToBig(INADDR_ANY)
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return bindResult >= 0
    }
    
    private func sendBroadcast() {
        guard socketFD >= 0 else { return }
        guard let broadcastIP = getWiFiBroadcastAddress() else { return }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UDP_PORT.bigEndian
        addr.sin_addr.s_addr = inet_addr(broadcastIP)
        
        let data = MAGIC_STRING.data(using: .utf8)!
        
        data.withUnsafeBytes { ptr in
            _ = sendto(socketFD, ptr.baseAddress, data.count, 0,
                       withUnsafePointer(to: &addr) {
                           $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                       },
                       socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    
    private func startReceivingLoop() {
            dispatchQueue.async { [weak self] in
                guard let self = self else { return }
                var buffer = [UInt8](repeating: 0, count: 2048)
                
                while self.isScanning && self.socketFD >= 0 {
                    let receivedBytes = recvfrom(self.socketFD, &buffer, buffer.count, 0, nil, nil)
                    if receivedBytes > 0 {
                        let data = Data(bytes: buffer, count: receivedBytes)
                        
                        // 🔥 [Debug] 強制印出原始封包內容
                        if let rawString = String(data: data, encoding: .utf8) {
                            print("📦 [Raw UDP Received]: \(rawString)")
                            
                            // 忽略自己的廣播回音
                            if rawString == MAGIC_STRING { continue }
                            
                            // 檢查關鍵字
                            if rawString.contains("ip") {
                                print("✅ 偵測到 IP 欄位，準備解析...")
                                DispatchQueue.main.async {
                                    self.handleSuccess(json: rawString)
                                }
                            } else {
                                print("⚠️ 收到封包但不包含 'ip' 欄位，忽略之。")
                            }
                        }
                    }
                }
            }
        }
    
    private func handleSuccess(json: String) {
        self.isConnected = true
        self.statusMessage = "✅ 已連線至阿卡核心"
        self.stopDiscovery()
        
        if let range = json.range(of: "ip") {
            let sub = json[range.upperBound...]
            let cleanIP = sub.split(separator: "\"").filter { $0.contains(".") }.first
                          ?? sub.split(separator: "'").filter { $0.contains(".") }.first
            
            if let ip = cleanIP {
                self.serverIP = String(ip)
            }
        }
    }
    
    private func getWiFiBroadcastAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    let addr = interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let mask = interface.ifa_netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let broadcastVal = (addr.sin_addr.s_addr & mask.sin_addr.s_addr) | (~mask.sin_addr.s_addr)
                    var broadcastAddr = sockaddr_in()
                    broadcastAddr.sin_family = sa_family_t(AF_INET)
                    broadcastAddr.sin_addr.s_addr = broadcastVal
                    return String(cString: inet_ntoa(broadcastAddr.sin_addr))
                }
            }
            ptr = interface.ifa_next
        }
        return nil
    }
}
