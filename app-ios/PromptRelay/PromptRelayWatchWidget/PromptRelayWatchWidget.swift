import SwiftUI
import WidgetKit

// スマートスタック / コンプリケーション用ウィジェット。
// 役割は「Watch アプリを開く入口」のみ。承認待ちの内容は表示しない
// (通知が届いても Watch アプリは起動せず、ウィジェットの内容を更新できないため)。
// アプリ側は起動時に届いている通知から承認待ちを拾うので、ここから開けば応答できる。

struct OpenAppEntry: TimelineEntry {
    let date: Date
}

struct OpenAppProvider: TimelineProvider {
    func placeholder(in context: Context) -> OpenAppEntry { OpenAppEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (OpenAppEntry) -> Void) {
        completion(OpenAppEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenAppEntry>) -> Void) {
        completion(Timeline(entries: [OpenAppEntry(date: .now)], policy: .never))
    }
}

struct OpenAppWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OpenAppEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "bell.badge")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompt Relay")
                        .font(.headline)
                    Text("承認待ちを開く")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label("Prompt Relay", systemImage: "bell.badge")
        case .accessoryCorner:
            Image(systemName: "bell.badge")
                .font(.title3)
                .widgetLabel { Text("Prompt Relay") }
        default:
            Image(systemName: "bell.badge")
                .font(.title2)
        }
    }
}

struct PromptRelayOpenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PromptRelayOpen", provider: OpenAppProvider()) { entry in
            OpenAppWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Prompt Relay")
        .description("承認待ちの確認画面を開きます")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

@main
struct PromptRelayWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        PromptRelayOpenWidget()
    }
}
