//
//  Apns_SchedulerApp.swift
//  Apns-Scheduler
//
//  Created by Muhammad Khalish Madani on 29/08/26.
//

import SwiftUI

@main
struct Apns_SchedulerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appDelegate.pushManager)
        }
    }
}
