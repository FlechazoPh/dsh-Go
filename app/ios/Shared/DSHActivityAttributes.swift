import ActivityKit
import Foundation

/// The Live Activity's attributes and dynamic state, shared by the Runner
/// app target and the LiveActivity widget extension target.
///
/// This file is compiled into BOTH targets (one PBXBuildFile entry per
/// target, same file reference). The two copies must stay identical, or
/// ActivityKit cannot decode the state the app posts.
///
/// iOS remote-only build, round 4: Live Activity / Dynamic Island.
/// - The fields mirror what Dart sends (`LiveActivity.toMap()` in
///   app/lib/notify/live_activity.dart, via `LivePush.toMap()`):
///   kind / title / text / chip / publicText / mood / sinceMs / eventId,
///   plus the pet pack id. `target` (host/sessionId) is not rendered and
///   is not carried: tapping the activity opens the app, Dart routes.
/// - Everything Dart sends is dynamic state; there are no static
///   attributes, so a pet-pack change does not force ending the activity
///   and requesting a new one.
/// - The state is kept small on purpose (short strings, one timestamp);
///   updates are local only, so the 4KB push limit does not apply, but
///   there is no reason to carry more.
/// - Deployment target of the extension is iOS 16.1 (the first release
///   with ActivityKit); the Runner app itself stays at iOS 15.0 and only
///   touches ActivityKit behind `#available(iOS 16.1, *)`.
@available(iOS 16.1, *)
struct DSHActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    /// "running" | "waiting" | "done" | "failed" (LiveKind.name).
    var kind: String
    /// Conversation title, already masked by Dart (alertTitle).
    var title: String
    /// One-line status text ("正在思考…" / "待确认" / …).
    var text: String
    /// A word or two for the chip / island ("思考中" / "待确认" / …).
    var chip: String
    /// Lock-screen line for hidden previews (unused on iOS: iOS has no
    /// per-activity redaction; kept so the two sides stay in sync).
    var publicText: String
    /// Pet state name (thinking / working / …); drives icon + tint.
    var mood: String
    /// Run start, epoch milliseconds; nil when the state has no clock.
    var sinceMs: Int64?
    /// The approval/question event id, when waiting on one.
    var eventId: String?
    /// Pet pack id; display only, the extension renders text + symbols.
    var packId: String?

    init(
      kind: String = "running",
      title: String = "",
      text: String = "",
      chip: String = "",
      publicText: String = "",
      mood: String = "thinking",
      sinceMs: Int64? = nil,
      eventId: String? = nil,
      packId: String? = nil
    ) {
      self.kind = kind
      self.title = title
      self.text = text
      self.chip = chip
      self.publicText = publicText
      self.mood = mood
      self.sinceMs = sinceMs
      self.eventId = eventId
      self.packId = packId
    }

    /// Elapsed-time start for the lock-screen / island timer, if any.
    var sinceDate: Date? {
      guard let sinceMs else { return nil }
      return Date(timeIntervalSince1970: TimeInterval(sinceMs) / 1000)
    }
  }
}
