//
//  PushNotificationManager.swift
//  Apns-Scheduler
//

import Foundation
import UIKit
import UserNotifications

/// Owns the APNs registration handshake and hands the resulting token to Supabase.
@MainActor
@Observable
final class PushNotificationManager: NSObject {

    enum State: Equatable {
        case idle
        case requesting
        case denied
        case registered(token: String)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// Ask iOS for permission, then for a device token. The token arrives
    /// asynchronously in the AppDelegate callback, not from this call.
    func register() async {
        state = .requesting
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                state = .denied
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Called from the AppDelegate once APNs hands back a token.
    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        state = .registered(token: token)
        Task { await store(token: token) }
    }

    func didFailToRegister(error: Error) {
        state = .failed(error.localizedDescription)
    }

    /// Upserts through `register_device`, which is security-definer so the
    /// anon key can write a token without being able to read the table.
    private func store(token: String) async {
        struct RegisterDevice: Encodable {
            let p_token: String
            let p_environment: String
        }
        do {
            let supabase = SupabaseConnector(config: try SupabaseConfig.fromInfoPlist())
            _ = try await supabase.rpc(
                "register_device",
                params: RegisterDevice(p_token: token, p_environment: Self.environment),
                returning: UUID.self
            )
        } catch {
            state = .failed("Token registered with APNs but not stored: \(error.localizedDescription)")
        }
    }

    /// Must match the `aps-environment` entitlement - APNs keeps separate
    /// token namespaces for sandbox and production, and a token minted in one
    /// is rejected by the other.
    private static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }
}

// MARK: - Foreground presentation

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    /// Without this, notifications arriving while the app is open are silently
    /// swallowed - which looks identical to a delivery failure while testing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
