import SwiftUI

// Watch 用コンパニオンアプリ (実験用の最小構成)。
// 目的は通知音ファイルを Watch 側の bundle に同梱すること。
// iPhone アプリの通知はミラー表示され、watchOS はペイロードの sound に
// 同名ファイルが Watch アプリ bundle にあればそれを鳴らす、という仕様を検証する。
@main
struct PromptRelayWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}

struct WatchContentView: View {
    @ObservedObject private var status = WatchStatus.shared
    @State private var showDetails = false
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let request = status.pendingRequest {
                    pendingCard(request)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "bell.badge")
                            .font(.title2)
                        Text("Prompt Relay")
                            .font(.headline)
                        Text(status.registerState == "登録済 (200)" ? "承認待ちの通知を開くとここで応答できます" : "iPhone の Prompt Relay を開いて接続してください")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                Divider()
                // 状態の詳細。Watch のログは Mac から読めないため画面に残す (watchOS に DisclosureGroup は無い)。
                Button {
                    showDetails.toggle()
                } label: {
                    Label("詳細 #\(status.counter)", systemImage: showDetails ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                if showDetails {
                    VStack(alignment: .leading, spacing: 4) {
                        row("build", Self.buildStamp)
                        row("Token", status.tokenState)
                        row("iPhone", status.phoneState)
                        row("登録", status.registerState)
                        row("直近", status.lastEvent)
                        Button("iPhone へ再送") {
                            appDelegate.sendTokenToPhone()
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .scenePadding(.horizontal)
        }
    }

    /// 応答待ちリクエスト。ボタンで iPhone 経由の即時送信を行う。
    private func pendingCard(_ request: WatchPendingRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.title)
                .font(.headline)
                .lineLimit(2)
            Text(request.body)
                .font(.caption2)
                .lineLimit(4)
            ForEach(request.choices) { choice in
                Button {
                    appDelegate.respond(to: request, choice: choice.number)
                } label: {
                    Text(choice.text)
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(request.isDestructive(choice) ? .red : .green)
                .disabled(status.sending)
                // 最初の選択肢 (Yes) をダブルタップ (人差し指と親指) に割り当てる。
                // 1 画面に 1 つしか割り当てられないため No は画面タップのまま。
                .doubleTapPrimaryAction(enabled: choice.id == request.choices.first?.id)
            }
            if status.sending {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 実行中バイナリの更新時刻。Watch 側で旧版が動いていないかを画面で判別するため。
    private static let buildStamp: String = {
        guard let url = Bundle.main.executableURL,
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { return "?" }
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f.string(from: date)
    }()

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption2)
        }
    }
}

private extension View {
    /// watchOS 11 以降のダブルタップ操作を、この画面の主ボタンに割り当てる。
    @ViewBuilder
    func doubleTapPrimaryAction(enabled: Bool) -> some View {
        if enabled, #available(watchOS 11.0, *) {
            self.handGestureShortcut(.primaryAction)
        } else {
            self
        }
    }
}
