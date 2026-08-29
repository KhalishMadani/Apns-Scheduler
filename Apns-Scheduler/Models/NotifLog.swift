//
//  NotifLog.swift
//  Apns-Scheduler
//

import Foundation

/// A row of `public."NotifLog"`, the record of notifications the app has handled.
nonisolated struct NotifLog: Codable, Sendable, Identifiable, Hashable {
    let uid: UUID
    let text: String
    let createdAt: Date

    var id: UUID { uid }

    enum CodingKeys: String, CodingKey {
        case uid
        case text
        case createdAt = "created_at"
    }
}

/// Insert payload. `uid` and `created_at` are filled by Postgres defaults,
/// so they're omitted rather than sent as client-chosen values.
nonisolated struct NewNotifLog: Encodable, Sendable {
    let text: String
}
