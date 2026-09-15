import Foundation
import UserNotifications
import WatchConnectivity
import WatchKit

// Watch アプリ側の通知処理。サーバとは直接通信せず、すべて iPhone アプリ経由にする。
//   - APNs トークン → iPhone (applicationContext + transferUserInfo)。iPhone がサーバへ登録する
//   - 承認応答 → 通知をタップしてアプリを開き、前面のボタンから iPhone へ sendMessage。iPhone がサーバへ転送する
// 通知自体は APNs から Watch アプリ宛てに直接届く (iPhone 経由ではない)。
// 通知にアクションボタンは付けない: ボタン処理中の Watch アプリはバックグラウンド扱いで
// sendMessage が使えず、キュー送信は iPhone アプリの前面復帰まで届かないため、
// 「押したのに反映されない」体験になる。
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate, WCSessionDelegate {
    private var deviceTokenHex: String {
        get { UserDefaults.standard.string(forKey: "deviceToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "deviceToken") }
    }

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        // サーバは category=PERMISSION_REQUEST を付けて送るが、Watch 側ではその
        // カテゴリを登録しない (未登録カテゴリはボタン無しの通知として表示される)。
        UNUserNotificationCenter.current().setNotificationCategories([])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("[PromptRelayWatch] notification auth granted=\(granted) error=\(String(describing: error))")
            DispatchQueue.main.async {
                WKApplication.shared().registerForRemoteNotifications()
            }
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// 前面に来たとき、承認待ちを取得して応答画面に載せ、前面の間は定期的に取り直す。
    /// 通知を見逃したり消したりしてからウィジェット等でアプリを開いた場合の入口。
    func applicationDidBecomeActive() {
        refreshPending()
        startPolling()
    }

    func applicationWillResignActive() {
        stopPolling()
    }

    // MARK: - 前面中の定期取得

    /// 前面の間だけ数秒おきに承認待ちを取り直す。通知の配送が遅れても、アプリを開いていれば
    /// ボタンが出る。別端末で応答済みになった枠も自動で消える。iPhone 経由の軽い問い合わせなので
    /// 前面限定なら電池への影響は小さい。
    private static let pollInterval: TimeInterval = 4
    private var pollTimer: Timer?
    private var refreshInFlight = false

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.refreshPending(quiet: true)
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// iPhone 経由でサーバの承認待ち一覧を取り、最新の 1 件を表示する。
    /// iPhone に届かないときは、届いている通知から拾う (通知を消していると何も出ない)。
    /// quiet: 定期取得用。状態が変わったときだけ表示を更新する。
    func refreshPending(quiet: Bool = false) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else {
            refreshPendingFromDeliveredNotifications()
            return
        }
        if refreshInFlight { return }
        refreshInFlight = true
        if !quiet { WatchStatus.shared.set(\.lastEvent, "承認待ちを iPhone に問い合わせ") }
        session.sendMessage(["request": "pending"], replyHandler: { reply in
            self.refreshInFlight = false
            guard reply["ok"] as? Bool == true, let list = reply["requests"] as? [[String: Any]] else {
                if !quiet { WatchStatus.shared.set(\.lastEvent, "問い合わせ失敗 (iPhone がサーバへ届かず)") }
                self.refreshPendingFromDeliveredNotifications()
                return
            }
            let newest = list
                .sorted { ($0["created_at"] as? Double ?? 0) > ($1["created_at"] as? Double ?? 0) }
                .compactMap { WatchPendingRequest(listItem: $0) }
                .first
            DispatchQueue.main.async {
                let current = WatchStatus.shared.pendingRequest?.id
                if let newest {
                    if current != newest.id {
                        WatchStatus.shared.setPending(newest)
                        WatchStatus.shared.set(\.lastEvent, "承認待ち \(list.count) 件")
                    } else if !quiet {
                        WatchStatus.shared.set(\.lastEvent, "承認待ち \(list.count) 件")
                    }
                } else if current != nil || !quiet {
                    // サーバに承認待ちが無い (別端末で応答済み等) → 表示を消す
                    WatchStatus.shared.setPending(nil)
                    WatchStatus.shared.set(\.lastEvent, "承認待ちなし")
                }
            }
        }, errorHandler: { error in
            self.refreshInFlight = false
            if !quiet { WatchStatus.shared.set(\.lastEvent, "問い合わせ不達 (\(error.localizedDescription))") }
            self.refreshPendingFromDeliveredNotifications()
        })
    }

    func refreshPendingFromDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let newest = notifications
                .sorted { $0.date > $1.date }
                .compactMap { Self.pendingRequest(from: $0) }
                .first
            guard let newest else { return }
            if WatchStatus.shared.pendingRequest?.id != newest.id {
                WatchStatus.shared.setPending(newest)
                WatchStatus.shared.set(\.lastEvent, "届いていた通知から承認待ちを表示")
            }
        }
    }

    // MARK: - APNs トークン → iPhone

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        deviceTokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("[PromptRelayWatch] device token: \(deviceTokenHex.prefix(16))...")
        WatchStatus.shared.set(\.tokenState, "取得済 \(deviceTokenHex.prefix(8))…")
        sendTokenToPhone()
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        print("[PromptRelayWatch] APNs registration failed: \(error)")
        WatchStatus.shared.set(\.tokenState, "失敗: \(error.localizedDescription)")
    }

    func sendTokenToPhone() {
        guard !deviceTokenHex.isEmpty else {
            WatchStatus.shared.set(\.phoneState, "トークン未取得")
            return
        }
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated else {
            WatchStatus.shared.set(\.phoneState, "WC 未活性")
            return
        }
        let payload: [String: Any] = ["watchToken": deviceTokenHex, "at": Date().timeIntervalSince1970]
        // applicationContext: 最新値を保持し iPhone アプリ起動時に読める。transferUserInfo: キュー配送で確実に届く。
        try? session.updateApplicationContext(payload)
        session.transferUserInfo(payload)
        WatchStatus.shared.set(\.phoneState, "iPhone へ送信 (reachable=\(session.isReachable))")
    }

    // MARK: - WatchConnectivity

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("[PromptRelayWatch] WCSession error: \(error)")
            WatchStatus.shared.set(\.lastEvent, "WC error: \(error.localizedDescription)")
        }
        if activationState == .activated {
            WatchStatus.shared.set(\.lastEvent, "WC activated")
            applyPhoneContext(session.receivedApplicationContext)
            sendTokenToPhone()
        }
    }

    // iPhone からの登録結果 (状態表示用)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyPhoneContext(applicationContext)
    }

    private func applyPhoneContext(_ context: [String: Any]) {
        if let result = context["registerResult"] as? String {
            WatchStatus.shared.set(\.registerState, result)
        }
    }

    // MARK: - 通知の表示と応答 (iPhone 経由)

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Self.logDelivery(notification, via: "前面")
        if let pending = Self.pendingRequest(from: notification) {
            WatchStatus.shared.setPending(pending)
        }
        completionHandler([.banner, .sound])
    }

    /// この request_id の通知を Watch から消す (通知タップ経由・一覧経由のどちらでも)
    private static func removeDeliveredNotifications(requestId: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { $0.request.content.userInfo["request_id"] as? String == requestId }
                .map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    private static func pendingRequest(from notification: UNNotification) -> WatchPendingRequest? {
        let content = notification.request.content
        return WatchPendingRequest(
            userInfo: content.userInfo,
            title: content.title,
            body: content.body,
            notificationIdentifier: notification.request.identifier
        )
    }

    // MARK: - 前面からの応答 (即時送信)

    /// Watch アプリが前面のときは sendMessage が使える (iPhone アプリはバックグラウンドで起こされる)。
    /// 通知ボタンからの応答はバックグラウンド扱いで sendMessage が失敗するため、前面 UI を主経路にする。
    func respond(to request: WatchPendingRequest, choice: Int) {
        let session = WCSession.default
        let message: [String: Any] = ["respondRequestId": request.id, "choice": choice]
        WatchStatus.shared.set(\.lastEvent, "送信中 choice=\(choice) (reachable=\(session.isReachable))")
        DispatchQueue.main.async { WatchStatus.shared.sending = true }
        session.sendMessage(message, replyHandler: { reply in
            let ok = reply["ok"] as? Bool ?? false
            let gone = reply["gone"] as? Bool ?? false
            let text = ok ? "OK" : (gone ? "既に応答済み (別端末で回答か期限切れ)" : "失敗 (iPhone がサーバへ送れず)")
            WatchStatus.shared.set(\.lastEvent, "応答 choice=\(choice) → \(text)")
            DispatchQueue.main.async {
                WatchStatus.shared.sending = false
                if ok || gone {
                    WatchStatus.shared.pendingRequest = nil
                    Self.removeDeliveredNotifications(requestId: request.id)
                }
                // 次の承認待ちがあれば表示し、無ければ枠を消した状態に揃える
                self.refreshPending()
            }
        }, errorHandler: { error in
            // iPhone に即時到達できない (圏外等) → キュー送信 (iPhone アプリの前面復帰時に届く)
            session.transferUserInfo(message)
            WatchStatus.shared.set(\.lastEvent, "応答 choice=\(choice) → iPhone 不達、後で送信 (\(error.localizedDescription))")
            DispatchQueue.main.async {
                WatchStatus.shared.sending = false
                WatchStatus.shared.pendingRequest = nil
            }
        })
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // 通知本文のタップ: アプリが前面に開くので、そこで応答する
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let pending = Self.pendingRequest(from: response.notification) {
            Self.logDelivery(response.notification, via: "タップ")
            WatchStatus.shared.setPending(pending)
            WatchStatus.shared.set(\.lastEvent, "通知を開いた")
        }
        completionHandler()
    }

    /// 通知の到着時刻 (watchOS が記録した値) を履歴に残す。人が秒を測らなくてよいようにする。
    private static func logDelivery(_ notification: UNNotification, via: String) {
        let id = (notification.request.content.userInfo["request_id"] as? String) ?? "?"
        WatchStatus.shared.log("通知到着 \(id) (\(via))", at: notification.date)
    }
}
