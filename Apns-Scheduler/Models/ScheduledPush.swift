//
//  ScheduledPush.swift
//  Apns-Scheduler
//

import Foundation

/// A row of `public.scheduled_push`: a notification queued to fire later.
/// The cron dispatcher moves due rows into `NotifLog`, whose trigger sends them.
nonisolated struct ScheduledPush: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let scheduledAt: Date
    let dispatchedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case scheduledAt = "scheduled_at"
        case dispatchedAt = "dispatched_at"
        case createdAt = "created_at"
    }
}

/// Insert payload. `id`, `dispatched_at` and `created_at` are filled by Postgres,
/// so only `text` and the fire time are sent.
nonisolated struct NewScheduledPush: Encodable, Sendable {
    let text: String
    let scheduledAt: Date

    enum CodingKeys: String, CodingKey {
        case text
        case scheduledAt = "scheduled_at"
    }
}
