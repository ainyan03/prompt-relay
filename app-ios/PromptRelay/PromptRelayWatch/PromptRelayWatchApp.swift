import SwiftUI
import WatchKit

// Watch 用コンパニオンアプリ。
// 通知はサーバから Watch アプリ宛てに直接届き (iPhone のミラーではない)、同梱した通知音で鳴る。
// 承認はこの画面のボタン (またはダブルタップ) で行い、iPhone アプリがサーバへ中継する。
// 前面に承認待ちが出たときは、iPhone の設定で選んだ音と振動でアプリ側から知らせる
// (watchOS は前面提示の通知音を鳴らさない)。「詳細」は Watch のログを Mac から読めない環境向けの状態表示。
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
    /// adaptor は App 側の 1 つだけ (View で再宣言すると別インスタンスが作られ、
    /// ポーリングや WCSession の状態が delegate 本体と分かれる)。
    private var appDelegate: WatchAppDelegate? {
        let d = WatchAppDelegate.shared ?? (WKApplication.shared().delegate as? WatchAppDelegate)
        if d == nil { WatchStatus.shared.log("delegate 未解決 (ボタン無効)") }
        return d
    }

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
                        Text("履歴（新しい順）").font(.caption2).foregroundStyle(.secondary)
                        ForEach(Array(status.eventLog.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced))
                        }
                        Button("承認待ちを更新") {
                            appDelegate?.refreshPending()
                        }
                        .font(.caption)
                        Button("iPhone へ再送") {
                            appDelegate?.sendTokenToPhone()
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
                    appDelegate?.respond(to: request, choice: choice.number)
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
