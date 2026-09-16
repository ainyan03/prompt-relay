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

    /// Watch が付けた順序番号 (インストール単位の epoch + 単調増加の seq)。applicationContext と
    /// transferUserInfo の両方で同じトークンが届き、古い方 (キュー配送が遅れた前のトークン) が後から
    /// 来ることがあるので、これで順序を決める。壁時計は巻き戻るので使わない。
    private var watchTokenEpoch: String {
        get { UserDefaults.standard.string(forKey: "watchTokenEpoch") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "watchTokenEpoch") }
    }
    private var watchTokenSeq: Int {
        get { UserDefaults.standard.integer(forKey: "watchTokenSeq") }
        set { UserDefaults.standard.set(newValue, forKey: "watchTokenSeq") }
    }
    /// 退役した epoch (再インストール前のもの)。そのキューが後から届いても採用しない。
    private var retiredEpochs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "watchTokenRetiredEpochs") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(20)), forKey: "watchTokenRetiredEpochs") }
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
            handleWatchToken(token, order: session.receivedApplicationContext, queued: false)
        }
    }

    // Watch 側の applicationContext (最新値のみ保持)。トークンはこれで受け取る。
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let token = applicationContext["watchToken"] as? String {
            handleWatchToken(token, order: applicationContext, queued: false)
        }
    }

    // transferUserInfo (キュー配送) 経由のトークン・応答。iPhone アプリが起きていなくても届く。
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let token = userInfo["watchToken"] as? String {
            handleWatchToken(token, order: userInfo, queued: true)
        }
        if let requestId = userInfo["respondRequestId"] as? String, let choice = userInfo["choice"] as? Int {
            appDelegate?.respondFromWatch(requestId: requestId, choice: choice, completion: nil)
        }
    }

    // sendMessage (即時・返信あり)。Watch アプリが前面のとき使われる。
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let token = message["watchToken"] as? String {
            handleWatchToken(token, order: message, queued: false)
            replyHandler(["ok": true])
            return
        }
        if let requestId = message["respondRequestId"] as? String, let choice = message["choice"] as? Int {
            appDelegate?.respondFromWatch(requestId: requestId, choice: choice) { outcome in
                // gone: 既に応答済み・期限切れ。Watch 側は成功と同様に枠を消してよい
                replyHandler(["ok": outcome == .sent, "gone": outcome == .gone])
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

    /// queued: transferUserInfo 経由 (キュー配送で、前のトークンが後から届きうる)。
    /// applicationContext と sendMessage は常に Watch の最新値なので順序に関係なく採用する。
    private func handleWatchToken(_ token: String, order: [String: Any], queued: Bool) {
        guard !token.isEmpty else { return }
        let previous = watchDeviceToken
        let changed = token != previous
        let epoch = order["epoch"] as? String
        let seq = order["seq"] as? Int
        // 順序の検証は token の変更有無と独立に行う (同じ token でも古い epoch/seq で状態を巻き戻さない)。
        // iPhone がまだ epoch を知らない (初回・旧版 Watch) なら順序は判定できないので受け入れる。
        if queued, !watchTokenEpoch.isEmpty {
            // 同じ epoch (同じインストール) で seq が現行以下なら遅着した古いトークン。
            // 順序番号の無い遅着 (旧版 Watch) と、退役済み epoch (再インストール前のキュー) も古いものとして扱う。
            // それ以外の epoch 違いは再インストールなので採用。
            let older = epoch == nil
                || (epoch == watchTokenEpoch && (seq ?? 0) <= watchTokenSeq)
                || epoch.map(retiredEpochs.contains) == true
            if older {
                print("[PromptRelay] Watch token ignored: queued and older than the current one (\(token.prefix(8))…)")
                return
            }
        }
        if let epoch, let seq {
            if !watchTokenEpoch.isEmpty, epoch != watchTokenEpoch { retiredEpochs.append(watchTokenEpoch) }
            watchTokenEpoch = epoch
            watchTokenSeq = seq
        }
        watchDeviceToken = token
        print("[PromptRelay] Watch token received: \(token.prefix(8))… changed=\(changed)")
        DispatchQueue.main.async {
            // トークンが変わったら古い方を解除する。残すと古い宛先にも送られ続け、
            // 直接配信が届かずミラー通知 (標準音) に落ちる。
            if changed, !previous.isEmpty {
                self.appDelegate?.unregisterStaleWatchToken(previous)
            }
            // 同じトークンでも登録し直す (Watch の「iPhone へ再送」やサーバ再起動後の復旧。単一飛行なので無害)
            self.appDelegate?.registerWatchTokenWithServer()
        }
    }

    /// Watch への登録結果通知 (状態画面用、届かなくてもよい)。
    /// sounds: 設定画面の通知音 (通知種別 → ファイル名)。Watch が前面で鳴らすときに使う。
    func notifyWatch(registerResult: String, sounds: [String: String]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext([
            "registerResult": registerResult,
            "sounds": sounds,
            "at": Date().timeIntervalSince1970,
        ])
    }
}
