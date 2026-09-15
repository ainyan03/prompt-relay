import Foundation

// Watch アプリの動作状態。Mac から Watch のログを読めない環境があるため、
// 登録の進み具合と失敗理由を画面に出して切り分けられるようにする。
final class WatchStatus: ObservableObject {
    static let shared = WatchStatus()

    @Published var tokenState = "未取得"
    @Published var phoneState = "未送信"
    @Published var registerState = "未実行"
    @Published var lastEvent = "-"
    @Published var counter = 0
    /// 前面で応答待ちのリクエスト (通知タップで開いたもの)
    @Published var pendingRequest: WatchPendingRequest? = nil
    @Published var sending = false

    func setPending(_ request: WatchPendingRequest?) {
        DispatchQueue.main.async {
            self.pendingRequest = request
            self.counter += 1
        }
    }

    func set(_ keyPath: ReferenceWritableKeyPath<WatchStatus, String>, _ value: String) {
        DispatchQueue.main.async {
            self[keyPath: keyPath] = value
            self.counter += 1
        }
    }
}
