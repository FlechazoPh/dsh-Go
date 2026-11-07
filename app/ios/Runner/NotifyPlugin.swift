import ActivityKit
import Flutter
import UIKit
import UserNotifications

/// iOS side of the `dsh/notify` channel (Android: NotifyPlugin.kt).
/// Local notifications only: the four chat alerts (turn done / failed-or-stopped /
/// approval / question). No push, no entitlements. Live Activity (ActivityKit)
/// is implemented here too (round 4): the widget extension in
/// app/ios/LiveActivity renders it; this plugin starts / updates / ends it
/// from what Dart pushes, and reports whether the system allows it.
/// - `live` takes a LivePush map {enabled, packId?, activity?} (see
///   app/lib/notify/notify_channel.dart). Enabled=false or activity=null
///   ends the activity; done/failed first update to the terminal text and
///   then end immediately, so a finished turn never lingers. Updates are
///   throttled to ~600ms (Android's interval) with a trailing update, so a
///   burst of pushes cannot spam ActivityKit.
/// - The activity only updates while the app process is alive. Once iOS
///   suspends the app after it goes to the background, the displayed state
///   freezes (same ceiling as local notifications; there is no push server
///   to update it remotely). Live Activities also end by themselves after
///   8 hours at most (staleDate is set to +8h on request).
/// - iOS has no per-notification lock-screen redaction, so Android's publicText
///   cannot be reproduced: the body is the real title/text. The person controls
///   lock-screen previews in system settings (Notifications → DSH Go →
///   Show Previews).
/// - `status` returns {enabled, done, attention}; `enabled` is the system
///   authorization state; done/attention are always true on iOS (no per-channel
///   blocking exists here).
/// - `show` posts a UNNotificationRequest whose identifier is "group|key" and
///   whose threadIdentifier is the group, so a newer turn replaces the older one.
/// - Taps go to the `dsh/notify/taps` stream, approval buttons to
///   `dsh/notify/actions`. A tap/action that arrives before Dart listens is held
///   and delivered on listen (same as Android's pendingTap).
/// - Authorization is requested lazily: `status` never prompts; `show` prompts
///   only while the app is in the foreground; the plugin also prompts once when
///   the app becomes active while authorization is still undecided and the
///   in-app notification switch is on (that switch lives in Dart prefs;
///   shared_preferences stores it in UserDefaults under "flutter.notify_enabled").
/// - iOS has no per-notification lock-screen redaction, so Android's publicText
///   cannot be reproduced: the body is the real title/text. The person controls
///   lock-screen previews in system settings (Notifications → DSH Go →
///   Show Previews).
final class NotifyPlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
  private static let channelName = "dsh/notify"
  private static let tapsChannelName = "dsh/notify/taps"
  private static let actionsChannelName = "dsh/notify/actions"
  private static let approvalCategory = "dsh.approval"
  private static let chatCategory = "dsh.chat"
  private static let allowOnceAction = "allowed-once"
  private static let rejectAction = "rejected"

  private var tapsSink: FlutterEventSink?
  private var actionsSink: FlutterEventSink?
  private var pendingTap: [String: Any]?
  private var pendingActions: [[String: Any]] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NotifyPlugin()
    let messenger = registrar.messenger()
    let methods = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    methods.setMethodCallHandler(instance.handle)
    let taps = FlutterEventChannel(name: tapsChannelName, binaryMessenger: messenger)
    taps.setStreamHandler(TapsStreamHandler(plugin: instance))
    let actions = FlutterEventChannel(name: actionsChannelName, binaryMessenger: messenger)
    actions.setStreamHandler(ActionsStreamHandler(plugin: instance))
    let center = UNUserNotificationCenter.current()
    center.delegate = instance
    // Approval buttons, in the approval card's order. Labels match Android's
    // zh strings (notify_allow_once / notify_decline); authentication is
    // required, as on Android (S+).
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: approvalCategory,
        actions: [
          UNNotificationAction(
            identifier: allowOnceAction, title: "允许本次", options: [.authenticationRequired]),
          UNNotificationAction(
            identifier: rejectAction, title: "拒绝", options: [.authenticationRequired]),
        ],
        intentIdentifiers: [],
        options: []),
      UNNotificationCategory(identifier: chatCategory, actions: [], intentIdentifiers: [], options: []),
    ])
    _ = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak instance] _ in instance?.requestAuthorizationIfNeeded() }
  }

  // MARK: - MethodChannel

  // Internal, not private: FlutterPlugin requires this method to be as
  // accessible as the type.
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "status":
      notificationSettings { settings in
        result([
          "enabled": settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral,
          "done": true,
          "attention": true,
        ])
      }
    case "show":
      guard let args = call.arguments as? [String: Any],
        let group = args["group"] as? String, !group.isEmpty,
        let key = args["key"] as? String, !key.isEmpty,
        let sessionId = args["sessionId"] as? String, !sessionId.isEmpty
      else {
        result(FlutterError(code: "bad_args", message: "group, key and sessionId are required", details: nil))
        return
      }
      show(args: args, group: group, key: key, result: result)
    case "cancel":
      if let args = call.arguments as? [String: Any],
        let group = args["group"] as? String, !group.isEmpty,
        let key = args["key"] as? String, !key.isEmpty
      {
        let id = identifier(group: group, key: key)
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
      }
      result(nil)
    case "cancelGroup":
      if let args = call.arguments as? [String: Any],
        let group = args["group"] as? String, !group.isEmpty
      {
        removeNotifications(threadIdentifier: group)
      }
      result(nil)
    case "cancelAll":
      center.removeAllPendingNotificationRequests()
      center.removeAllDeliveredNotifications()
      result(nil)
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        result(true)
      } else {
        result(false)
      }
    case "actionResult":
      // Minimal: drop the delivered notification once Dart answered the tap.
      // (Android replaces it with a short status line; that needs native
      // strings and is not reproduced here.)
      if let args = call.arguments as? [String: Any],
        let group = args["group"] as? String, !group.isEmpty,
        let key = args["key"] as? String, !key.isEmpty
      {
        center.removeDeliveredNotifications(withIdentifiers: [identifier(group: group, key: key)])
      }
      result(nil)
    case "live":
      // Live Activity: start / update / end from the LivePush Dart sends.
      // Dart ignores the return value; answer at once and do the
      // ActivityKit work on a Task (request/update/end are async).
      if #available(iOS 16.1, *) {
        live16(args: call.arguments as? [String: Any])
      }
      result(nil)
    case "liveStatus":
      // LiveSystemStatus.fromMap reads these three; native defaults to true
      // when a map is returned.
      if #available(iOS 16.1, *) {
        result([
          "supported": true,
          "allowed": ActivityAuthorizationInfo().areActivitiesEnabled,
          "settings": true,
        ])
      } else {
        result(["supported": false, "allowed": false, "settings": false])
      }
    case "openLiveSettings":
      // iOS has no deep link straight to the per-app Live Activities
      // switch; the app's own settings page holds it (Notifications →
      // DSH Go → Live Activities), so open that.
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        result(true)
      } else {
        result(false)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Posting

  private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

  private func notificationSettings(_ completion: @escaping (UNNotificationSettings) -> Void) {
    center.getNotificationSettings { settings in
      // Flutter results must be answered on the main thread.
      DispatchQueue.main.async { completion(settings) }
    }
  }

  private func show(args: [String: Any], group: String, key: String, result: @escaping FlutterResult) {
    notificationSettings { [weak self] settings in
      guard let self = self else { result(nil); return }
      switch settings.authorizationStatus {
      case .authorized, .provisional, .ephemeral:
        self.post(args: args, group: group, key: key)
        result(nil)
      case .notDetermined:
        if UIApplication.shared.applicationState == .active {
          // The system prompt only appears while the app is in the foreground.
          self.requestAuthorization { [weak self] granted in
            if granted { self?.post(args: args, group: group, key: key) }
            result(nil)
          }
        } else {
          // Dropped silently: the app is leaving the screen, so the prompt
          // cannot appear now. The didBecomeActive prompt covers the next
          // return to the app.
          result(nil)
        }
      default:
        // Denied: nothing to post, and never prompt again from here.
        result(nil)
      }
    }
  }

  private func post(args: [String: Any], group: String, key: String) {
    let content = UNMutableNotificationContent()
    content.title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "DSH Go"
    // Expanded text when Dart has one, else the plain line.
    content.body = (args["fullText"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? (args["text"] as? String ?? "")
    content.threadIdentifier = group
    content.categoryIdentifier = (args["canApprove"] as? Bool == true) ? Self.approvalCategory : Self.chatCategory
    content.sound = .default
    // .active for both kinds: .timeSensitive / .critical need entitlements.
    content.interruptionLevel = .active
    var userInfo: [String: Any] = [
      "group": group,
      "key": key,
      "sessionId": args["sessionId"] as? String ?? "",
      "host": args["host"] as? String ?? "",
      "kind": args["kind"] as? String ?? "",
    ]
    if let eventId = args["eventId"] as? String { userInfo["eventId"] = eventId }
    content.userInfo = userInfo
    let request = UNNotificationRequest(
      identifier: identifier(group: group, key: key), content: content, trigger: nil)
    center.add(request)
  }

  private func identifier(group: String, key: String) -> String { "\(group)|\(key)" }

  private func removeNotifications(threadIdentifier: String) {
    center.getDeliveredNotifications { [weak self] delivered in
      let ids = delivered
        .filter { $0.request.content.threadIdentifier == threadIdentifier }
        .map { $0.request.identifier }
      if !ids.isEmpty { self?.center.removeDeliveredNotifications(withIdentifiers: ids) }
    }
    center.getPendingNotificationRequests { [weak self] pending in
      let ids = pending
        .filter { $0.content.threadIdentifier == threadIdentifier }
        .map { $0.identifier }
      if !ids.isEmpty { self?.center.removePendingNotificationRequests(withIdentifiers: ids) }
    }
  }

  // MARK: - Live Activity (ActivityKit, iOS 16.1+)

  // The box holds the running Activity. It is stored as `Any` because the
  // Activity type itself is only available on iOS 16.1+ while this target
  // still deploys to iOS 15.0; every access goes through `#available`.
  private var liveBox: Any?

  @available(iOS 16.1, *)
  private func live16(args: [String: Any]?) {
    let enabled = args?["enabled"] as? Bool ?? false
    let activity = args?["activity"] as? [String: Any]
    // packId rides on the LivePush itself, not inside the activity map.
    let packId = args?["packId"] as? String
    Task { [weak self] in
      guard let self else { return }
      let box: LiveActivityBox
      if let existing = self.liveBox as? LiveActivityBox {
        box = existing
      } else {
        box = LiveActivityBox()
        self.liveBox = box
      }
      await box.apply(enabled: enabled, activity: activity, packId: packId)
      if box.activity == nil { self.liveBox = nil }
    }
  }

  // MARK: - Authorization

  private func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      DispatchQueue.main.async { completion?(granted) }
    }
  }

  private func requestAuthorizationIfNeeded() {
    // The in-app switch lives in Dart prefs; absent means the Dart default (on).
    let enabled = UserDefaults.standard.object(forKey: "flutter.notify_enabled") as? Bool ?? true
    guard enabled else { return }
    notificationSettings { [weak self] settings in
      if settings.authorizationStatus == .notDetermined {
        self?.requestAuthorization()
      }
    }
  }

  // MARK: - Stream sinks

  fileprivate func tapsListening(_ sink: @escaping FlutterEventSink) {
    tapsSink = sink
    if let pending = pendingTap {
      pendingTap = nil
      sink(pending)
    }
  }

  fileprivate func tapsCancelled() { tapsSink = nil }

  fileprivate func actionsListening(_ sink: @escaping FlutterEventSink) {
    actionsSink = sink
    if !pendingActions.isEmpty {
      let queued = pendingActions
      pendingActions = []
      queued.forEach { sink($0) }
    }
  }

  fileprivate func actionsCancelled() { actionsSink = nil }

  private func deliverTap(userInfo: [AnyHashable: Any]) {
    guard let sessionId = userInfo["sessionId"] as? String, !sessionId.isEmpty else { return }
    var tap: [String: Any] = [
      "sessionId": sessionId,
      "host": userInfo["host"] as? String ?? "",
    ]
    if let kind = userInfo["kind"] as? String { tap["kind"] = kind }
    if let eventId = userInfo["eventId"] as? String { tap["eventId"] = eventId }
    if let sink = tapsSink {
      sink(tap)
    } else {
      pendingTap = tap
    }
  }

  private func deliverAction(userInfo: [AnyHashable: Any], decision: String) {
    guard let group = userInfo["group"] as? String, !group.isEmpty,
      let key = userInfo["key"] as? String, !key.isEmpty,
      let eventId = userInfo["eventId"] as? String, !eventId.isEmpty,
      let host = userInfo["host"] as? String, !host.isEmpty
    else { return }
    let action: [String: Any] = [
      "host": host,
      "group": group,
      "key": key,
      "eventId": eventId,
      "decision": decision,
    ]
    if let sink = actionsSink {
      sink(action)
    } else {
      pendingActions.append(action)
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }
    let userInfo = response.notification.request.content.userInfo
    switch response.actionIdentifier {
    case UNNotificationDefaultActionIdentifier:
      deliverTap(userInfo: userInfo)
    case Self.allowOnceAction, Self.rejectAction:
      deliverAction(userInfo: userInfo, decision: response.actionIdentifier)
    default:
      break
    }
  }
}

private final class TapsStreamHandler: NSObject, FlutterStreamHandler {
  private weak var plugin: NotifyPlugin?

  init(plugin: NotifyPlugin) { self.plugin = plugin }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    plugin?.tapsListening(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    plugin?.tapsCancelled()
    return nil
  }
}

private final class ActionsStreamHandler: NSObject, FlutterStreamHandler {
  private weak var plugin: NotifyPlugin?

  init(plugin: NotifyPlugin) { self.plugin = plugin }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    plugin?.actionsListening(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    plugin?.actionsCancelled()
    return nil
  }
}

/// Owns the one running Live Activity for the `dsh/notify` channel.
///
/// iOS 16.1+ only (the whole class is gated; the Runner target still
/// deploys to iOS 15.0). The state it posts is built from the LivePush map
/// Dart sends (`LiveActivity.toMap()`); the widget extension renders it.
///
/// Rules, mirroring Android's LiveActivity.kt:
/// - No activity exists and the push is a terminal kind (done/failed):
///   nothing is started just to end it.
/// - Terminal kinds on a live activity: update to the terminal text first,
///   then end with `.immediate` so the finished turn does not linger.
/// - Anything else: start if none exists, else update. Equal states are
///   not re-posted (Dart already dedupes, this is the second net).
/// - Updates are throttled to ~600ms; a push that arrives inside the
///   window is coalesced into one trailing update instead of being lost.
/// - A request is only made while `areActivitiesEnabled` is true; a denied
///   system switch fails silently and `liveStatus` is how Dart finds out.
@available(iOS 16.1, *)
private final class LiveActivityBox {
  private static let minUpdateInterval: TimeInterval = 0.6
  /// Live Activities end by themselves after 8 hours at most.
  private static let maxLifetime: TimeInterval = 8 * 3600

  var activity: Activity<DSHActivityAttributes>?
  private var lastState: DSHActivityAttributes.ContentState?
  private var lastUpdate = Date.distantPast
  private var pendingUpdate: Task<Void, Never>?

  /// Applies one LivePush. Pushes arrive one at a time from Dart's bridge
  /// (equal pushes are deduped there), so concurrent calls are rare; the
  /// throttle's trailing task is cancelled by a newer push, and a terminal
  /// push always wins over a pending update. Worst case for a race is one
  /// stale intermediate state on the island until the next push.
  func apply(enabled: Bool, activity dict: [String: Any]?, packId: String?) async {
    pendingUpdate?.cancel()
    pendingUpdate = nil
    guard enabled, let dict else {
      await endCurrent()
      return
    }
    let state = LiveActivityBox.state(from: dict, packId: packId)
    let terminal = state.kind == "done" || state.kind == "failed"
    if let current = activity {
      if terminal {
        lastState = state
        lastUpdate = Date()
        await current.update(state)
        await current.end(state, dismissalPolicy: .immediate)
        self.activity = nil
        lastState = nil
      } else if state != lastState {
        await updateThrottled(current: current, state: state)
      }
      return
    }
    // No activity running.
    guard !terminal else { return }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    do {
      let content = ActivityContent(
        state: state,
        staleDate: Date().addingTimeInterval(Self.maxLifetime))
      let requested = try Activity.request(
        attributes: DSHActivityAttributes(), content: content)
      activity = requested
      lastState = state
      lastUpdate = Date()
    } catch {
      // Disabled, or the system refused the request: stay silent.
      // `liveStatus` is the channel Dart uses to learn about it.
    }
  }

  private func updateThrottled(current: Activity<DSHActivityAttributes>, state: DSHActivityAttributes.ContentState) async {
    let elapsed = Date().timeIntervalSince(lastUpdate)
    if elapsed >= Self.minUpdateInterval {
      lastState = state
      lastUpdate = Date()
      await current.update(state)
      return
    }
    // Inside the window: one trailing update carrying the newest state.
    let delay = Self.minUpdateInterval - elapsed
    pendingUpdate = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard let self, !Task.isCancelled else { return }
      guard let current = self.activity else { return }
      self.lastState = state
      self.lastUpdate = Date()
      await current.update(state)
    }
    // Await the trailing update so a terminal push that follows it does
    // not race ahead of the state it replaces.
    await pendingUpdate?.value
  }

  private func endCurrent() async {
    pendingUpdate?.cancel()
    pendingUpdate = nil
    guard let current = activity else { return }
    activity = nil
    lastState = nil
    await current.end(nil, dismissalPolicy: .immediate)
  }

  private static func state(from dict: [String: Any], packId: String?) -> DSHActivityAttributes.ContentState {
    let string = { (key: String) -> String in dict[key] as? String ?? "" }
    let sinceMs: Int64? = {
      if let n = dict["sinceMs"] as? NSNumber { return n.int64Value }
      if let n = dict["sinceMs"] as? Int { return Int64(n) }
      return nil
    }()
    return DSHActivityAttributes.ContentState(
      kind: string("kind"),
      title: string("title"),
      text: string("text"),
      chip: string("chip"),
      publicText: string("publicText"),
      mood: string("mood"),
      sinceMs: sinceMs,
      eventId: dict["eventId"] as? String,
      packId: packId
    )
  }
}
