import ActivityKit
import SwiftUI
import WidgetKit

/// Live Activity widget extension (iOS remote-only build, round 4).
///
/// The extension renders only the Live Activity: lock screen + Dynamic
/// Island (compact / expanded / minimal). There is deliberately no Home
/// Screen widget here.
///
/// Views are text + timer + status colour / SF Symbol only. No pet images
/// are copied into the extension: the pet picture lives in the app bundle
/// and the island is meant to be glanced at, not admired.
///
/// iOS 27 note: `EnvironmentValues.isDynamicIslandLimitedInWidth` is the
/// only iOS 27 symbol used, and only behind `#if compiler(>=6.3)` (Xcode 27
/// ships Swift 6.3; the workflow prints `swift --version` so the log shows
/// which side was taken). Under Xcode 26 the symbol is compiled out and
/// the island falls back to the plain title. Never use `EmptyView` as a
/// compactLeading/compactTrailing placeholder: on iOS 27 a placeholder
/// stretches the island tall; both sides always carry real content.
///
/// What the states mean (mirrors Android's LiveActivity.kt):
/// running/waiting = live, counting up from `since`; done/failed = the app
/// first updates to the terminal text, then ends the activity immediately,
/// so a finished turn never lingers on the lock screen.
@available(iOS 16.2, *)
struct DSHLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DSHActivityAttributes.self) { context in
      lockScreen(context: context)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          VStack(alignment: .leading, spacing: 2) {
            IslandTitleText(text: context.state.title.isEmpty ? "DSH Go" : context.state.title)
            Text(context.state.text)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing, spacing: 2) {
            Text(context.state.chip)
              .font(.headline)
              .lineLimit(1)
            if let since = context.state.sinceDate, isLiveKind(context.state.kind) {
              Text(since, style: .timer)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 6) {
            Image(systemName: iconName(for: context.state))
              .foregroundStyle(tint(for: context.state))
            Text(kindLabel(for: context.state.kind))
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Text("DSH Go")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      } compactLeading: {
        Image(systemName: iconName(for: context.state))
          .foregroundStyle(tint(for: context.state))
      } compactTrailing: {
        // Real content on both sides of the island (see the header note):
        // a live clock while it runs/waits, otherwise the status chip.
        if let since = context.state.sinceDate, isLiveKind(context.state.kind) {
          Text(since, style: .timer)
            .monospacedDigit()
        } else {
          Text(context.state.chip)
            .lineLimit(1)
        }
      } minimal: {
        Image(systemName: iconName(for: context.state))
          .foregroundStyle(tint(for: context.state))
      }
    }
  }

  // MARK: - Lock screen

  private func lockScreen(context: ActivityViewContext<DSHActivityAttributes>) -> some View {
    let state = context.state
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: iconName(for: state))
          .foregroundStyle(tint(for: state))
        Text(state.title.isEmpty ? "DSH Go" : state.title)
          .font(.headline)
          .lineLimit(1)
        Spacer()
        Text(state.chip)
          .font(.caption)
          .lineLimit(1)
      }
      Text(state.text)
        .font(.subheadline)
        .lineLimit(2)
      if let since = state.sinceDate, isLiveKind(state.kind) {
        Text(since, style: .timer)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }
}

// MARK: - State mapping

@available(iOS 16.2, *)
private func isLiveKind(_ kind: String) -> Bool {
  kind == "running" || kind == "waiting"
}

@available(iOS 16.2, *)
private func iconName(for state: DSHActivityAttributes.ContentState) -> String {
  switch state.kind {
  case "waiting": return "questionmark.bubble.fill"
  case "done": return "checkmark.circle.fill"
  case "failed": return "exclamationmark.triangle.fill"
  default: return "ellipsis.bubble.fill"
  }
}

@available(iOS 16.2, *)
private func tint(for state: DSHActivityAttributes.ContentState) -> Color {
  switch state.kind {
  case "waiting": return .orange
  case "done": return .green
  case "failed": return .red
  default: return .blue
  }
}

@available(iOS 16.2, *)
private func kindLabel(for kind: String) -> String {
  switch kind {
  case "waiting": return "待确认"
  case "done": return "已完成"
  case "failed": return "出错"
  default: return "运行中"
  }
}

/// The expanded island's title. On iOS 27 the island can be narrower than
/// usual (landscape, and the vertical island); there the title is shortened
/// instead of being cut off mid-word. The full title stays on the lock
/// screen, and under older SDKs this is just a plain one-line title.
@available(iOS 16.2, *)
private struct IslandTitleText: View {
  let text: String

  var body: some View {
#if compiler(>=6.3)
    if #available(iOS 27.0, *) {
      NarrowIslandTitleText(text: text)
    } else {
      Text(text).font(.headline).lineLimit(1)
    }
#else
    Text(text).font(.headline).lineLimit(1)
#endif
  }
}

#if compiler(>=6.3)
/// iOS 27 only. Compiled out entirely under Xcode 26 / Swift < 6.3, so the
/// same source builds on both toolchains (see the workflow's fallback).
@available(iOS 27.0, *)
private struct NarrowIslandTitleText: View {
  @Environment(\.isDynamicIslandLimitedInWidth) private var limitedInWidth
  let text: String

  var body: some View {
    Text(limitedInWidth ? String(text.prefix(10)) : text)
      .font(.headline)
      .lineLimit(1)
  }
}
#endif

@available(iOS 16.2, *)
@main
struct DSHLiveActivityBundle: WidgetBundle {
  var body: some Widget {
    DSHLiveActivityWidget()
  }
}
