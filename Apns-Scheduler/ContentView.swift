//
//  ContentView.swift
//  Apns-Scheduler
//
//  Created by Muhammad Khalish Madani on 29/08/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        PushNotifView()
    }
}

#Preview {
    ContentView()
        .environment(PushNotificationManager())
}
