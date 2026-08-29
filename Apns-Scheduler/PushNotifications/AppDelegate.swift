//
//  AppDelegate.swift
//  Apns-Scheduler
//

import UIKit
import UserNotifications

/// APNs token delivery is only exposed through UIApplicationDelegate, so a
/// SwiftUI app still needs one of these.
final class AppDelegate: NSObject, UIApplicationDelegate {

    let pushManager = PushNotificationManager()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = pushManager
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        MainActor.assumeIsolated {
            pushManager.didRegister(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        MainActor.assumeIsolated {
            pushManager.didFailToRegister(error: error)
        }
    }
}
