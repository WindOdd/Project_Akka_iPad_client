//
//  Project_Akka_iPad_clientApp.swift
//  Project_Akka_iPad_client
//
//  Created by Sam Lai on 2025/12/30.
//

import SwiftUI

@main
struct Project_Akka_iPad_clientApp: App {
    init() {
            PermissionsManager.shared.requestAllPermissions()
        }
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
