//
//  PermissionsManager.swift
//  Project_Akka_iPad_client
//
//  Created by Sam Lai on 2026/1/3.
//

import Foundation
import AVFoundation
import Network
import Combine  // 👈 必須加入這行，才能使用 ObservableObject
class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()
    
    // 用於發布權限狀態給 UI (如果需要製作權限引導頁面可用)
    @Published var micPermissionGranted = false
    
    // 請求所有必要的權限
    func requestAllPermissions() {
        requestMicrophonePermission()
        triggerLocalNetworkPermission()
    }
    
    // 1. 請求麥克風權限
    private func requestMicrophonePermission() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined:
            print("🎤 [Permissions] 請求麥克風權限...")
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    self.micPermissionGranted = granted
                    if granted {
                        print("🎤 [Permissions] 麥克風權限已取得")
                    } else {
                        print("🚫 [Permissions] 麥克風權限被拒絕")
                    }
                }
            }
        case .granted:
            print("✅ [Permissions] 麥克風權限先前已取得")
            self.micPermissionGranted = true
        case .denied:
            print("🚫 [Permissions] 麥克風權限先前已被拒絕")
            self.micPermissionGranted = false
        @unknown default:
            break
        }
    }
    
    // 2. 觸發區域網路權限 (Local Network)
    // iOS 沒有直接的 API 可以 "請求" 或 "檢查" 區域網路權限。
    // 唯一的方法是嘗試進行一次網路操作 (如 UDP 廣播或 Bonjour 掃描)，系統就會跳出視窗。
    private func triggerLocalNetworkPermission() {
        print("🌐 [Permissions] 嘗試觸發區域網路權限視窗...")
        
        // 使用 NWConnection 進行一個虛擬的連接嘗試，這通常比 BSD Socket 更能穩定觸發 iOS 的隱私彈窗
        let params = NWParameters.udp
        let connection = NWConnection(host: "255.255.255.255", port: 37020, using: params)
        
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("🌐 [Permissions] 網路準備就緒 (這通常代表權限已過或彈窗已處理)")
                connection.cancel()
            case .failed(let error):
                print("⚠️ [Permissions] 觸發網路連線失敗 (可能是權限被拒): \(error)")
                connection.cancel()
            case .waiting(let error):
                print("⏳ [Permissions] 等待網路權限: \(error)")
            default:
                break
            }
        }
        
        connection.start(queue: .global())
    }
}
