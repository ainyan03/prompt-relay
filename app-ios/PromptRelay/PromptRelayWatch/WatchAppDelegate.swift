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
    /// adaptor が生成した唯一のインスタンス。View はこれを使う (WKApplication.shared().delegate は
    /// SwiftUI の adaptor 経由だと実機で nil になり、ボタンが何もしなくなった)。
    private(set) static weak var shared: WatchAppDelegate?

    override init() {
        super.init()
        WatchAppDelegate.shared = self
    }

    private var deviceTokenHex: String {
        get { UserDefaults.standard.string(forKey: "deviceToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "deviceToken") }
    }

    /// トークンの順序を iPhone に伝えるための番号。壁時計は巻き戻るので使わない。
    /// epoch はインストールごとに 1 つ (再インストールで変わる)、seq はトークンが変わるたびに増える。
    private var tokenEpoch: String {
        if let e = UserDefaults.standard.string(forKey: "tokenEpoch") { return e }
        let e = UUID().uuidString
        UserDefaults.standard.set(e, forKey: "tokenEpoch")
        return e
    }
    private var tokenSeq: Int {
        get { UserDefaults.standard.integer(forKey: "tokenSeq") }
        set { UserDefaults.standard.set(newValue, forKey: "tokenSeq") }
    }

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        // サーバは category=PERMISSION_REQUEST を付けて送るが、Watch 側ではその
        // カテゴリを登録しない (未登録カテゴリはボタン無しの通知として表示される)。
        UNUserNotificationCenter.current().setNotificationCategories([])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("[PromptRelayWatch] notification auth granted=\(granted) error=\(String(describing: error))")
            // 権限が無くてもトークン登録は通るので、状態画面で区別できるようにしておく
            if !granted { WatchStatus.shared.set(\.lastEvent, "通知権限なし (Watch の設定で許可が要る)") }
            // time-sensitive が Watch 側で効いているか (2 = 有効)。無効なら Watch の設定 → 通知で切り替えられる
            UNUserNotificationCenter.current().getNotificationSettings { st in
                WatchStatus.shared.log("通知設定 auth=\(st.authorizationStatus.rawValue) alert=\(st.alertSetting.rawValue) sound=\(st.soundSetting.rawValue) timeSensitive=\(st.timeSensitiveSetting.rawValue)")
            }
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
        logDeliveredNotifications()
        // 前面でない間に出た枠 (鳴らせていない) を、前面に戻った時点で知らせる
        if let current = WatchStatus.shared.pendingRequest { WatchStatus.shared.setPending(current) }
        // 前面復帰の直後は iPhone が「不達」になりやすい (実測: 直後は失敗、4 秒後の次回は成功)。
        // 到達可能ならすぐ、そうでなければ 1 秒だけ待ってから問い合わせる。
        if WCSession.isSupported(), WCSession.default.activationState == .activated, !WCSession.default.isReachable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard WKApplication.shared().applicationState == .active else { return }
                self?.refreshPending()
            }
        } else {
            refreshPending()
        }
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
        // 問い合わせ前に届いていた通知だけを掃除の対象にする。一覧の取得中に届いた新しい承認は
        // 一覧に載っていなくても未解決なので消してはいけない。
        UNUserNotificationCenter.current().getDeliveredNotifications { before in
            let snapshot = Set(before.map(\.request.identifier))
            self.sendPendingQuery(session: session, quiet: quiet, deliveredBefore: snapshot)
        }
    }

    private func sendPendingQuery(session: WCSession, quiet: Bool, deliveredBefore snapshot: Set<String>) {
        // WCSession の返信は任意のキューで来る。状態 (refreshInFlight / dismissedIds / 表示) は main でだけ触る。
        session.sendMessage(["request": "pending"], replyHandler: { reply in
            DispatchQueue.main.async {
                self.refreshInFlight = false
                guard reply["ok"] as? Bool == true, let list = reply["requests"] as? [[String: Any]] else {
                    if !quiet { WatchStatus.shared.set(\.lastEvent, "問い合わせ失敗 (iPhone がサーバへ届かず)") }
                    self.refreshPendingFromDeliveredNotifications()
                    return
                }
                // サーバが承認待ちと言っていない通知は応答済み・期限切れ・キャンセル済み。
                // 残すと iPhone 不達時のフォールバックが古い承認を再表示する。
                // 残す集合は生の request_id 全件から作る (Watch で表示できない形の承認待ちも通知は残す)。
                let listedIds = Set(list.compactMap { $0["request_id"] as? String })
                Self.removeDeliveredNotifications(among: snapshot, exceptRequestIds: listedIds)
                let pending = list
                    .sorted { ($0["created_at"] as? Double ?? 0) > ($1["created_at"] as? Double ?? 0) }
                    .compactMap { WatchPendingRequest(listItem: $0) }
                    .filter { !self.dismissedIds.contains($0.id) }
                let newest = pending.first
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
            DispatchQueue.main.async {
                self.refreshInFlight = false
                if !quiet { WatchStatus.shared.set(\.lastEvent, "問い合わせ不達 (\(error.localizedDescription))") }
                self.refreshPendingFromDeliveredNotifications()
            }
        })
    }

    /// 背景で届いた通知の到着時刻を履歴に残す (配信のずれを測るため。watchOS が記録した date を使う)
    private func logDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            for n in notifications.sorted(by: { $0.date < $1.date }) {
                guard let id = n.request.content.userInfo["request_id"] as? String else { continue }
                WatchStatus.shared.log("配信済 \(id)", at: n.date)
            }
        }
    }

    func refreshPendingFromDeliveredNotifications() {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let candidates = notifications
                .sorted { $0.date > $1.date }
                .compactMap { Self.pendingRequest(from: $0) }
            DispatchQueue.main.async {
                guard let newest = candidates.first(where: { !self.dismissedIds.contains($0.id) }) else { return }
                if WatchStatus.shared.pendingRequest?.id != newest.id {
                    WatchStatus.shared.setPending(newest)
                    WatchStatus.shared.set(\.lastEvent, "届いていた通知から承認待ちを表示")
                }
            }
        }
    }

    // MARK: - APNs トークン → iPhone

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        if hex != deviceTokenHex { tokenSeq += 1 }
        deviceTokenHex = hex
        print("[PromptRelayWatch] device token: \(deviceTokenHex.prefix(16))... seq=\(tokenSeq)")
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
        let payload: [String: Any] = [
            "watchToken": deviceTokenHex,
            "epoch": tokenEpoch,
            "seq": tokenSeq,
            "at": Date().timeIntervalSince1970,
        ]
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
            // 起動直後の applicationDidBecomeActive は activation 前で iPhone に問い合わせられない。
            // 活性化した時点で前面なら取り直す (次のポーリングまで待たせない)。
            DispatchQueue.main.async {
                if WKApplication.shared().applicationState == .active { self.refreshPending(quiet: true) }
            }
        }
    }

    // MARK: - サーバからの dismiss (サイレントプッシュ)

    /// 別端末で応答済み・キャンセル・期限切れになったリクエストの通知と枠を消す。
    /// Info.plist の WKBackgroundModes (remote-notification) が要る。背景プッシュは遅延・破棄されうるので、
    /// 前面での取り直し (refreshPending) と二重に効かせる。
    func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        guard userInfo["type"] as? String == "dismiss", let requestId = userInfo["request_id"] as? String else {
            completionHandler(.noData)
            return
        }
        WatchStatus.shared.log("dismiss \(requestId)")
        // 状態更新を先に main で済ませてから通知を消し、その完了で fetch completion を返す。
        // 逆順だと completion 後にプロセスが止まり、main 側の更新が走らないことがある。
        DispatchQueue.main.async {
            self.markDismissed(requestId)
            if WatchStatus.shared.pendingRequest?.id == requestId { WatchStatus.shared.setPending(nil) }
            Self.removeDeliveredNotifications(requestId: requestId) { removed in
                completionHandler(removed ? .newData : .noData)
            }
        }
    }

    /// dismiss を受けた request_id (新しい順)。dismiss より前に出した一覧要求の返信が後から届いても、
    /// その ID で枠を復活させない。サーバが応答済みを承認待ちとして返すことは無いので、除外して安全。
    /// プロセス再起動をまたいで遅着する承認本体も抑止できるよう永続化する。
    private lazy var dismissedIds: [String] = UserDefaults.standard.stringArray(forKey: "dismissedRequestIds") ?? []
    private static let maxDismissed = 200

    private func markDismissed(_ id: String) {
        dismissedIds.insert(id, at: 0)
        if dismissedIds.count > Self.maxDismissed { dismissedIds.removeLast() }
        UserDefaults.standard.set(dismissedIds, forKey: "dismissedRequestIds")
    }

    // iPhone からの登録結果 (状態表示用)
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        applyPhoneContext(applicationContext)
    }

    private func applyPhoneContext(_ context: [String: Any]) {
        if let result = context["registerResult"] as? String {
            WatchStatus.shared.set(\.registerState, result)
        }
        // 前面で鳴らす音 (設定画面の承認リクエスト用の音)。標準なら nil。
        let sounds = context["sounds"] as? [String: String]
        WatchStatus.shared.foregroundSoundFile = sounds?["permission_request"]
    }

    // MARK: - 通知の表示と応答 (iPhone 経由)

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Self.logDelivery(notification, via: "前面")
        guard let pending = Self.pendingRequest(from: notification) else {
            completionHandler([.banner, .sound])   // 完了通知など、承認待ち以外
            return
        }
        DispatchQueue.main.async {
            if self.dismissedIds.contains(pending.id) {
                // dismiss が先に届いた承認の本体が遅れて来た。解決済みなので出さない。
                completionHandler([])
                return
            }
            if WKApplication.shared().applicationState == .active {
                // 画面が点いていてこのアプリが前面: 音と振動はアプリ側で出す (設定の音 + 振動)。
                // 実機確認: active 中に .sound を返しても watchOS は音も振動も出さない。
                // .play: この通知自身が配信済み一覧に載る前後の競合を避けるため、配信済み判定を通さない。
                WatchStatus.shared.setPending(pending, alert: .play)
                completionHandler([.banner])
            } else {
                // アプリは最前面だが画面が消えている (inactive): アプリ側の play(_:) は効かず、手首を上げるまで
                // 鳴らせない。通常の通知として OS に鳴らさせ (即時)、アプリ側では鳴らさない。
                WatchStatus.shared.setPending(pending, alert: .silent)
                WatchStatus.shared.log("前面(inactive) OS 提示 \(pending.id)")
                completionHandler([.banner, .sound])
            }
        }
    }

    /// この request_id の通知を Watch から消す (通知タップ経由・一覧経由のどちらでも)
    private static func removeDeliveredNotifications(requestId: String, completion: ((Bool) -> Void)? = nil) {
        removeDeliveredNotifications(where: { $0 == requestId }, completion: completion)
    }

    /// 承認待ちでなくなった通知をまとめて消す (サーバの一覧を正とする)。対象は一覧を要求した時点で
    /// 届いていた通知 (among) に限る。一覧が空でも消す: サーバ再起動後などに残る通知は、応答しても 404 にしかならない。
    private static func removeDeliveredNotifications(among identifiers: Set<String>, exceptRequestIds keep: Set<String>) {
        removeDeliveredNotifications(where: { identifier, requestId in
            identifiers.contains(identifier) && !keep.contains(requestId)
        })
    }

    private static func removeDeliveredNotifications(where shouldRemove: @escaping (String) -> Bool, completion: ((Bool) -> Void)? = nil) {
        removeDeliveredNotifications(where: { _, requestId in shouldRemove(requestId) }, completion: completion)
    }

    /// shouldRemove(通知の identifier, request_id)
    private static func removeDeliveredNotifications(where shouldRemove: @escaping (String, String) -> Bool, completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications
                .filter { n in
                    let info = n.request.content.userInfo
                    guard info["type"] as? String == "permission_request", let id = info["request_id"] as? String else { return false }
                    return shouldRemove(n.request.identifier, id)
                }
                .map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            completion?(!ids.isEmpty)
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
            // iPhone に即時到達できない (圏外等) → キュー送信 (iPhone アプリの前面復帰時に届く)。
            // サーバ受理を確認していないので枠は残す。届いて解決すれば次の取り直しで消える。
            session.transferUserInfo(message)
            WatchStatus.shared.set(\.lastEvent, "応答 choice=\(choice) → iPhone 不達、後で送信 (\(error.localizedDescription))")
            DispatchQueue.main.async { WatchStatus.shared.sending = false }
        })
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // 通知本文のタップ: アプリが前面に開くので、そこで応答する (通知が既に鳴っているので振動させない)
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let pending = Self.pendingRequest(from: response.notification) {
            Self.logDelivery(response.notification, via: "タップ")
            WatchStatus.shared.setPending(pending, alert: .silent)
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
