import Foundation
import WatchConnectivity

// iPhone 側の Watch 連携。Watch はサーバと直接通信せず、すべて iPhone 経由にする。
//   - Watch → iPhone: APNs トークン (transferUserInfo: 到達保証あり)、承認応答 (sendMessage)
//   - iPhone → サーバ: Watch トークンの登録/解除 (platform=watchos、通知音は設定画面の値)、応答の転送
// 理由: Watch の通信は iPhone の VPN (Tailscale) を通らず、自己署名 CA も配布できないため、
// サーバに到達できる保証があるのは iPhone だけ。通知の配信 (APNs → Watch) は Apple 経由で
// 別経路なので、この制約を受けない。
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    /// Watch トークンを受け取ったとき / 応答を受け取ったときの処理先
    weak var appDelegate: AppDelegate?

    private(set) var watchDeviceToken: String {
        get { UserDefaults.standard.string(forKey: "watchDeviceToken") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "watchDeviceToken") }
    }

    var isWatchAppInstalled: Bool {
        WCSession.isSupported() && WCSession.default.isWatchAppInstalled
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error {
            print("[PromptRelay] WCSession activation error: \(error)")
        }
        if activationState == .activated, let token = session.receivedApplicationContext["watchToken"] as? String {
            handleWatchToken(token)
        }
    }

    // Watch 側の applicationContext (最新値のみ保持)。トークンはこれで受け取る。
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let token = applicationContext["watchToken"] as? String {
            handleWatchToken(token)
        }
    }

    // transferUserInfo (キュー配送) 経由のトークン・応答。iPhone アプリが起きていなくても届く。
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let token = userInfo["watchToken"] as? String {
            handleWatchToken(token)
        }
        if let requestId = userInfo["respondRequestId"] as? String, let choice = userInfo["choice"] as? Int {
            appDelegate?.respondFromWatch(requestId: requestId, choice: choice, completion: nil)
        }
    }

    // sendMessage (即時・返信あり)。Watch アプリが前面のとき使われる。
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let token = message["watchToken"] as? String {
            handleWatchToken(token)
            replyHandler(["ok": true])
            return
        }
        if let requestId = message["respondRequestId"] as? String, let choice = message["choice"] as? Int {
            appDelegate?.respondFromWatch(requestId: requestId, choice: choice) { success in
                replyHandler(["ok": success])
            }
            return
        }
        // Watch アプリが前面に来たときの承認待ち一覧要求。通知を消した後でも応答できるようにする。
        if message["request"] as? String == "pending" {
            guard let appDelegate else {
                replyHandler(["ok": false, "error": "not ready"])
                return
            }
            appDelegate.fetchPendingRequestsForWatch { requests in
                replyHandler(["ok": requests != nil, "requests": requests ?? []])
            }
            return
        }
        replyHandler(["ok": false, "error": "unknown message"])
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    // MARK: - 内部

    private func handleWatchToken(_ token: String) {
        guard !token.isEmpty else { return }
        let previous = watchDeviceToken
        let changed = token != previous
        watchDeviceToken = token
        print("[PromptRelay] Watch token received: \(token.prefix(8))… changed=\(changed)")
        DispatchQueue.main.async {
            // トークンが変わったら古い方を解除する。残すと古い宛先にも送られ続け、
            // 直接配信が届かずミラー通知 (標準音) に落ちる。
            if changed, !previous.isEmpty {
                self.appDelegate?.unregisterStaleWatchToken(previous)
            }
            self.appDelegate?.registerWatchTokenWithServer()
        }
    }

    /// Watch への登録結果通知 (状態画面用、届かなくてもよい)
    func notifyWatch(registerResult: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["registerResult": registerResult, "at": Date().timeIntervalSince1970])
    }
}
