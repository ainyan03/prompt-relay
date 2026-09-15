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
        WatchStatus.shared.set(\.lastEvent, "通知受信(前面)")
        if let pending = Self.pendingRequest(from: notification) {
            WatchStatus.shared.setPending(pending)
        }
        completionHandler([.banner, .sound])
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
            WatchStatus.shared.set(\.lastEvent, "応答 choice=\(choice) → \(ok ? "OK" : "失敗 (iPhone がサーバへ送れず)")")
            DispatchQueue.main.async {
                WatchStatus.shared.sending = false
                if ok {
                    WatchStatus.shared.pendingRequest = nil
                    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.notificationIdentifier])
                }
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
            WatchStatus.shared.setPending(pending)
            WatchStatus.shared.set(\.lastEvent, "通知を開いた")
        }
        completionHandler()
    }
}
