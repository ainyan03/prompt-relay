import AVFoundation
import Foundation
import UserNotifications
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

    /// 履歴に積み、標準出力にも流す (devicectl --console で Mac から読めるようにするため)。main で呼ぶ。
    private func appendLog(_ line: String) {
        eventLog.insert(line, at: 0)
        if eventLog.count > Self.maxLog { eventLog.removeLast() }
        print("[PromptRelayWatch] \(line)")
    }

    /// 履歴にだけ残す (lastEvent は変えない)
    func log(_ text: String, at date: Date = Date()) {
        Self.onMain {
            self.appendLog("\(Self.stamp(date)) \(text)")
        }
    }
    /// 前面で応答待ちのリクエスト (通知タップで開いたもの)
    @Published var pendingRequest: WatchPendingRequest? = nil
    @Published var sending = false

    /// 一度知らせた request_id (新しい順)。同じ枠が消えて再表示されても再度は鳴らさない。
    private var alertedIds: [String] = []
    private static let maxAlerted = 200
    /// 前面到着 (.play) だったが inactive に落ちた瞬間で鳴らせなかった ID。通知は .sound 無しで出ているので
    /// 「配信済み = 鳴った」とは扱わず、次に前面へ戻ったとき必ず鳴らす。
    private var foregroundMissed: Set<String> = []

    /// 新しい枠を出したとき、利用者にどう知らせるか。
    enum AlertPolicy {
        /// 前面なら必ず鳴らす。前面で通知が到着した経路 (willPresent) 用。通知は .sound を返さないので
        /// ここで鳴らさないと 0 回になる。配信済み一覧は見ない (今まさに届いた通知自身が載りうる)。
        case play
        /// 前面なら鳴らすが、同じ request_id の通知が既に配信済みなら鳴らさない (背景で通知として鳴った
        /// 承認を、アイコンやウィジェットから開いた場合)。ポーリング・通知一覧フォールバック用。
        case playUnlessDelivered
        /// 鳴らさない。通知タップで開いた経路 (通知自体が鳴っている)。
        case silent
    }

    /// ポーリングで見つけた承認待ちは通知経路を通らないので、鳴らさないと画面を見ていない限り気付けない。
    /// request_id ごとに 1 回だけ鳴らす。
    /// main から呼ばれたら同期で処理する。willPresent → setPending → play が同じ main ターンで完結しないと、
    /// completion を返した後に inactive へ落ちて鳴らせないことがある (dismiss の順序保証も同じ理由)。
    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    func setPending(_ request: WatchPendingRequest?, alert: AlertPolicy = .playUnlessDelivered) {
        let now = Date()
        Self.onMain {
            let changed = self.pendingRequest?.id != request?.id
            self.pendingRequest = request
            self.counter += 1
            if changed {
                let text = request.map { "枠表示 \($0.id)" } ?? "枠消去"
                self.appendLog("\(Self.stamp(now)) \(text)")
            }
            // 同じ ID でも、まだ知らせていなければ鳴らす (前面でない間に枠が出て、後で前面に戻った場合)。
            guard let id = request?.id, !self.alertedIds.contains(id) else { return }
            switch alert {
            case .silent:
                self.markAlerted(id)
            case .play:
                if !self.playIfActive(id) { self.foregroundMissed.insert(id) }
            case .playUnlessDelivered:
                guard WKApplication.shared().applicationState == .active else { return }
                if self.foregroundMissed.contains(id) {
                    if self.playIfActive(id) { self.foregroundMissed.remove(id) }
                    return
                }
                UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                    let alreadyAnnounced = delivered.contains { $0.request.content.userInfo["request_id"] as? String == id }
                    DispatchQueue.main.async {
                        guard !self.alertedIds.contains(id), self.pendingRequest?.id == id else { return }
                        if alreadyAnnounced {
                            self.markAlerted(id)
                        } else {
                            self.playIfActive(id)
                        }
                    }
                }
            }
        }
    }

    /// play(_:) は前面 (active) のときしか効かない。鳴らせなかった ID は記録せず、次に前面で
    /// 枠を出す機会 (activation 後の取り直し等) に鳴らす。main で呼ぶ。
    /// 前面で鳴らす音のファイル名 (iPhone の設定画面の値。applicationContext で届く)。nil なら標準。
    var foregroundSoundFile: String? {
        get { UserDefaults.standard.string(forKey: "foregroundSoundFile") }
        set { UserDefaults.standard.set(newValue, forKey: "foregroundSoundFile") }
    }
    private var player: AVAudioPlayer?

    @discardableResult
    private func playIfActive(_ id: String) -> Bool {
        guard WKApplication.shared().applicationState == .active else { return false }
        markAlerted(id)
        // 設定で選んだ音があれば同梱ファイルを再生し、振動は音の付かない .click にする。
        // 無ければ標準の通知ハプティクス (音付き)。watchOS は前面提示の通知音を鳴らさないので自前で出す。
        if let file = foregroundSoundFile, let url = Bundle.main.url(forResource: file, withExtension: nil),
           let p = try? AVAudioPlayer(contentsOf: url) {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = p
            p.play()
            WKInterfaceDevice.current().play(.click)
            log("振動+音 \(file) \(id)")
        } else {
            WKInterfaceDevice.current().play(.notification)
            log("振動 \(id)")
        }
        return true
    }

    private func markAlerted(_ id: String) {
        alertedIds.insert(id, at: 0)
        if alertedIds.count > Self.maxAlerted { alertedIds.removeLast() }
    }

    func set(_ keyPath: ReferenceWritableKeyPath<WatchStatus, String>, _ value: String) {
        let now = Date()
        Self.onMain {
            self[keyPath: keyPath] = value
            self.counter += 1
            if keyPath == \.lastEvent {
                self.appendLog("\(Self.stamp(now)) \(value)")
            }
        }
    }
}
