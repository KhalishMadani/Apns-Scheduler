//
//  PushNotif.swift
//  Apns-Scheduler
//
//  Created by Muhammad Khalish Madani on 29/08/26.
//

import SwiftUI

/// Sends one fixed NotifLog row to Supabase. Smoke test for the
/// Secrets.xcconfig -> Info.plist -> SupabaseConnector -> PostgREST path.
struct PushNotifView: View {

    private static let payloadText = "halo from the iOS apn scheduler"

    /// How far ahead of the tap the notification fires.
    private static let leadTime: TimeInterval = 5 * 60

    private enum Status {
        case idle
        case sending
        case sent(uid: UUID, at: Date)
        case failed(String)
    }

    @State private var status: Status = .idle
    @Environment(PushNotificationManager.self) private var pushManager

    var body: some View {
        VStack(spacing: 20) {
            Text(Self.payloadText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await send() }
            } label: {
                Group {
                    if isSending {
                        ProgressView()
                    } else {
                        Text("Schedule push (+5 min)")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSending)

            statusLabel

            Divider()

            registrationLabel
        }
        .padding()
        .animation(.default, value: isSending)
        .task {
            // Safe to call on every launch - iOS only prompts the first time,
            // and re-registering refreshes a token that changed.
            await pushManager.register()
        }
    }

    private var isSending: Bool {
        if case .sending = status { return true }
        return false
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .idle:
            EmptyView()
        case .sending:
            Text("Posting…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .sent(uid, at):
            VStack(spacing: 4) {
                Label("Scheduled", systemImage: "clock.badge.checkmark")
                    .foregroundStyle(.green)
                Text(uid.uuidString)
                    .font(.caption2.monospaced())
                Text("fires at \(at.formatted(.dateTime.hour().minute().second()))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(spacing: 4) {
                Label("Failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var registrationLabel: some View {
        switch pushManager.state {
        case .idle, .requesting:
            Text("Registering for push…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .denied:
            Label("Notifications denied - enable in Settings", systemImage: "bell.slash")
                .font(.caption)
                .foregroundStyle(.orange)
        case let .registered(token):
            VStack(spacing: 2) {
                Label("APNs token registered", systemImage: "bell.badge.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(token.prefix(16) + "…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
    }

    private func send() async {
        status = .sending
        do {
            // Cheap to build - it only holds the config and URLSession.shared.
            let supabase = SupabaseConnector(config: try SupabaseConfig.fromInfoPlist())
            let fireAt = Date().addingTimeInterval(Self.leadTime)
            let inserted: [ScheduledPush] = try await supabase.insert(
                [NewScheduledPush(text: Self.payloadText, scheduledAt: fireAt)],
                into: "scheduled_push",
                returning: ScheduledPush.self
            )
            guard let row = inserted.first else {
                status = .failed("Insert returned no rows.")
                return
            }
            status = .sent(uid: row.id, at: row.scheduledAt)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

#Preview {
    PushNotifView()
        .environment(PushNotificationManager())
}
