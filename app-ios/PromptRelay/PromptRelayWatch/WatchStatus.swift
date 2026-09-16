import Foundation
import WatchKit

// Watch アプリの動作状態。Mac から Watch のログを読めない環境があるため、
// 登録の進み具合と失敗理由を画面に出して切り分けられるようにする。
final class WatchStatus: ObservableObject {
    static let shared = WatchStatus()

    @Published var tokenState = "未取得"
    @Published var phoneState = "未送信"
    @Published var registerState = "未実行"
    @Published var lastEvent = "-"
    @Published var counter = 0
    /// 時刻付きの直近イベント (新しい順)。人が秒を測らずに済むように Watch 側で記録する。
    @Published var eventLog: [String] = []
    private static let maxLog = 12

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.S"
        return f
    }()

    static func stamp(_ date: Date = Date()) -> String {
        timeFormatter.string(from: date)
    }

    /// 履歴にだけ残す (lastEvent は変えない)
    func log(_ text: String, at date: Date = Date()) {
        DispatchQueue.main.async {
            self.eventLog.insert("\(Self.stamp(date)) \(text)", at: 0)
            if self.eventLog.count > Self.maxLog { self.eventLog.removeLast() }
        }
    }
    /// 前面で応答待ちのリクエスト (通知タップで開いたもの)
    @Published var pendingRequest: WatchPendingRequest? = nil
    @Published var sending = false

    /// 一度知らせた request_id (新しい順)。同じ枠が消えて再表示されても再度は鳴らさない。
    private var alertedIds: [String] = []
    private static let maxAlerted = 20

    /// alert: 新しい枠を出すとき、前面なら音と振動で知らせる。ポーリングで見つけた承認待ちは
    /// 通知経路を通らないので、これが無いと画面を見ていない限り気付けない。
    /// 通知タップで開いた場合は通知自体が鳴っているので false にする。
    func setPending(_ request: WatchPendingRequest?, alert: Bool = true) {
        let now = Date()
        DispatchQueue.main.async {
            let changed = self.pendingRequest?.id != request?.id
            self.pendingRequest = request
            self.counter += 1
            guard changed else { return }
            let text = request.map { "枠表示 \($0.id)" } ?? "枠消去"
            self.eventLog.insert("\(Self.stamp(now)) \(text)", at: 0)
            if self.eventLog.count > Self.maxLog { self.eventLog.removeLast() }
            guard let id = request?.id, !self.alertedIds.contains(id) else { return }
            self.alertedIds.insert(id, at: 0)
            if self.alertedIds.count > Self.maxAlerted { self.alertedIds.removeLast() }
            // play(_:) は前面 (active) のときしか効かない。背景では通知そのものが鳴る。
            if alert, WKApplication.shared().applicationState == .active {
                WKInterfaceDevice.current().play(.notification)
                self.log("振動 \(id)")
            }
        }
    }

    func set(_ keyPath: ReferenceWritableKeyPath<WatchStatus, String>, _ value: String) {
        let now = Date()
        DispatchQueue.main.async {
            self[keyPath: keyPath] = value
            self.counter += 1
            if keyPath == \.lastEvent {
                self.eventLog.insert("\(Self.stamp(now)) \(value)", at: 0)
                if self.eventLog.count > Self.maxLog { self.eventLog.removeLast() }
            }
        }
    }
}
