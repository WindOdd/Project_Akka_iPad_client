// Services/UDPDiscoveryService.swift
import Foundation
import Network
import Combine
import Darwin

let UDP_PORT: UInt16 = 37020
let MAGIC_STRING = "DISCOVER_AKKA_SERVER"

class UDPDiscoveryService: ObservableObject {
    @Published var serverIP: String?
    @Published var isConnected: Bool = false
    @Published var statusMessage: String = "準備連線..."
    
    private var socketFD: Int32 = -1
    private var isListening = false
    private var retryTimer: Timer?
    // 使用獨立的佇列來處理接收，避免卡住 UI
    private let dispatchQueue = DispatchQueue(label: "com.akka.udp.bsd", qos: .userInitiated)
    
    // 啟動
    func startDiscovery() {
        stopDiscovery()
        print("🚀 [Ultimate BSD] 啟動搜尋 (智慧廣播 + 持續監聽)...")
        
        self.isConnected = false
        self.statusMessage = "正在呼叫阿卡主機..."
        
        // 1. 建立 Socket
        if setupSocket() {
            // 2. 開始在背景聽
            startReceivingLoop()
            // 3. 開始定時喊話
            startBroadcastingTimer()
        }
    }
    
    func stopDiscovery() {
        retryTimer?.invalidate()
        retryTimer = nil
        isListening = false
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }
    
    // --- 1. 建立底層 Socket ---
    private func setupSocket() -> Bool {
        socketFD = socket(AF_INET, SOCK_DGRAM, 0)
        guard socketFD >= 0 else {
            print("❌ Socket 建立失敗")
            return false
        }
        
        // 允許廣播
        var broadcastEnable = 1
        setsockopt(socketFD, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int>.size))
        
        // 綁定到隨機 Port (讓 OS 自動分配，例如 54321)
        // 這樣我們送出時 Source Port 就是 54321，Server 也會回給 54321，我們就在這裡接
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // 0 = Random Port
        addr.sin_addr.s_addr = CFSwapInt32HostToBig(INADDR_ANY)
        
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        
        return bindResult >= 0
    }
    
    // --- 2. 發送廣播 (結合智慧 IP 計算) ---
    private func sendBroadcast() {
        guard socketFD >= 0 else { return }
        
        // ★ 自動計算廣播 IP (例如 192.168.50.255)
        guard let broadcastIP = getWiFiBroadcastAddress() else {
            print("⚠️ 找不到 Wi-Fi，跳過發送")
            return
        }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UDP_PORT.bigEndian
        addr.sin_addr.s_addr = inet_addr(broadcastIP) // 使用算出來的 IP
        
        let data = MAGIC_STRING.data(using: .utf8)!
        
        data.withUnsafeBytes { ptr in
            let sent = sendto(socketFD, ptr.baseAddress, data.count, 0,
                              withUnsafePointer(to: &addr) {
                                  $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                              },
                              socklen_t(MemoryLayout<sockaddr_in>.size))
            
            if sent > 0 {
                // print("📡 已發送廣播至 \(broadcastIP)")
            } else {
                print("❌ 發送失敗: \(String(cString: strerror(errno)))")
            }
        }
    }
    
    // --- 3. 接收迴圈 (不會被 IP 過濾擋住) ---
    private func startReceivingLoop() {
        isListening = true
        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            
            while self.isListening && self.socketFD >= 0 {
                // 這裡會停下來等資料 (Blocking)
                let receivedBytes = recvfrom(self.socketFD, &buffer, buffer.count, 0, nil, nil)
                
                if receivedBytes > 0 {
                    let data = Data(bytes: buffer, count: receivedBytes)
                    if let jsonString = String(data: data, encoding: .utf8) {
                        // 忽略自己發出去的回音
                        if jsonString == MAGIC_STRING { continue }
                        
                        print("📥 [收到回應] \(jsonString)")
                        if jsonString.contains("ip") {
                            DispatchQueue.main.async {
                                self.handleSuccess(json: jsonString)
                            }
                            // 收到後若想停止廣播，可在此處處理
                        }
                    }
                }
            }
        }
    }
    
    private func startBroadcastingTimer() {
        sendBroadcast()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.isConnected { self.sendBroadcast() }
        }
    }
    
    private func handleSuccess(json: String) {
        self.isConnected = true
        self.statusMessage = "✅ 已連線至阿卡核心"
        self.retryTimer?.invalidate() // 停止重試
        
        // 簡易抓取 IP
        if let range = json.range(of: "ip") {
            let sub = json[range.upperBound...]
            // 過濾掉 JSON 符號，只留 IP 字串
            let cleanIP = sub.split(separator: "\"").filter { $0.contains(".") }.first
                          ?? sub.split(separator: "'").filter { $0.contains(".") }.first
            
            if let ip = cleanIP {
                self.serverIP = String(ip)
            }
        }
    }
    
    // --- 工具：計算 Wi-Fi 廣播 IP ---
    private func getWiFiBroadcastAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        while ptr != nil {
            let interface = ptr!.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" { // iOS Wi-Fi
                    let addr = interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    let mask = interface.ifa_netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    
                    let ipVal = addr.sin_addr.s_addr
                    let maskVal = mask.sin_addr.s_addr
                    let broadcastVal = (ipVal & maskVal) | (~maskVal)
                    
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
