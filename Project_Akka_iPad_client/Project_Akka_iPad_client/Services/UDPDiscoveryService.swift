import Foundation
import Network
import Combine
import Darwin

let UDP_PORT: UInt16 = 37020
let MAGIC_STRING = "DISCOVER_AKKA_SERVER"
struct UDPConfig {
    static let port: UInt16 = 37020
    static let magicString = "DISCOVER_AKKA_SERVER"
    static let maxRetries = 6
    static let maxCycles = 10
}
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
    
    // 用於取消延遲任務的 WorkItem
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
            scheduleNextBroadcast(delay: 0.1)
        } else {
            self.isScanning = false
            self.statusMessage = "Socket 初始化失敗"
        }
    }
    
    func stopDiscovery() {
        pendingTask?.cancel()
        pendingTask = nil
        isScanning = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }
    
    // MARK: - Logic Core
    
    private func scheduleNextBroadcast(delay: TimeInterval) {
        let task = DispatchWorkItem { [weak self] in
            self?.performBroadcastStep()
        }
        self.pendingTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    
    private func performBroadcastStep() {
        guard isScanning && !isConnected else { return }
        
        if currentRetry >= maxRetriesPerCycle {
            handleCycleCompletion()
            return
        }
        
        currentRetry += 1
        self.statusMessage = "搜尋中 (輪次 \(currentCycle + 1)/\(maxCycles) - 次數 \(currentRetry)/\(maxRetriesPerCycle))..."
        
        sendBroadcast()
        
        // 隨機間隔避免碰撞
        let randomInterval = Double.random(in: 1.0...3.0)
        scheduleNextBroadcast(delay: randomInterval)
    }
    
    private func handleCycleCompletion() {
        currentCycle += 1
        if currentCycle >= maxCycles {
            print("⚠️ UDP 搜尋徹底失敗 (10輪結束)")
            stopDiscovery()
            self.statusMessage = "找不到主機，請手動設定 IP"
            return
        }
        print("⏳ 第 \(currentCycle) 輪搜尋結束，冷卻 \(Int(cooldownSeconds)) 秒...")
        self.statusMessage = "暫無回應，\(Int(cooldownSeconds)) 秒後重試..."
        currentRetry = 0
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
    
    // 🔥 [核心修正] 發送廣播邏輯
    private func sendBroadcast() {
        guard socketFD >= 0 else {
            print("❌ Socket 未就緒")
            return
        }
        
        // 1. 取得真正可用的廣播位址 (避開 255.255.255.255，也避開 nil)
        guard let broadcastIP = getWiFiBroadcastAddress() else {
            print("⚠️ 無法找到任何支援廣播的活躍網卡 (請檢查 WiFi 連線)")
            // 這裡不再使用 255.255.255.255 當保底，因為 iOS 會擋
            return
        }
        
        // print("📡 發送 UDP 廣播至: \(broadcastIP)") // Debug
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UDPConfig.port.bigEndian
        addr.sin_addr.s_addr = inet_addr(broadcastIP)
        
        let data = UDPConfig.magicString.data(using: .utf8)!
        
        data.withUnsafeBytes { ptr in
            let result = sendto(socketFD, ptr.baseAddress, data.count, 0,
                       withUnsafePointer(to: &addr) {
                           $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                       },
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            
            if result < 0 {
                let errorString = String(cString: strerror(errno))
                print("❌ UDP 發送失敗: \(errorString) (Error: \(errno))")
            }
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
                    if let rawString = String(data: data, encoding: .utf8) {
                        // print("📦 [UDP]: \(rawString)") // Debug
                        
                        if rawString == MAGIC_STRING { continue }
                        
                        if rawString.contains("ip") {
                            print("✅ 收到 Server 回應，準備解析...")
                            DispatchQueue.main.async {
                                self.handleSuccess(json: rawString)
                            }
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
    
    // 🔥 [核心修正] 智慧尋找正確的廣播位址 (移除 en0 限制)
    private func getWiFiBroadcastAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            
            // 1. 必須是 IPv4
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let flags = Int32(interface.ifa_flags)
                
                // 2. 必須是 開啟(UP) 且 支援廣播(BROADCAST) 且 不是Loopback
                let isUp = (flags & (IFF_UP)) == (IFF_UP)
                let isLoopback = (flags & (IFF_LOOPBACK)) == (IFF_LOOPBACK)
                let supportsBroadcast = (flags & (IFF_BROADCAST)) == (IFF_BROADCAST)
                
                if isUp && !isLoopback && supportsBroadcast {
                    let name = String(cString: interface.ifa_name)
                    
                    // 3. 計算子網域廣播位址 (Subnet Directed Broadcast)
                    // 這是最安全的做法，算出來類似 192.168.1.255，iOS 不會擋
                    let addr = interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let mask = interface.ifa_netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    
                    // Broadcast = (IP | ~Mask)
                    let broadcastVal = (addr.sin_addr.s_addr | (~mask.sin_addr.s_addr))
                    
                    var broadcastAddr = sockaddr_in()
                    broadcastAddr.sin_family = sa_family_t(AF_INET)
                    broadcastAddr.sin_addr.s_addr = broadcastVal
                    
                    let ipString = String(cString: inet_ntoa(broadcastAddr.sin_addr))
                    
                    // 4. 只要找到合法的網卡就回傳 (不再檢查是否叫 en0)
                    // 通常 en 開頭的是 WiFi，bridge 開頭的是熱點，這些都可用
                    print("✅ 發現可用網卡: \(name), 廣播位址: \(ipString)")
                    return ipString
                }
            }
            ptr = interface.ifa_next
        }
        
        return nil
    }
}
