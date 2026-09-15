import UIKit
import UserNotifications
import Security

private enum KeychainStore {
    private static let service = Bundle.main.bundleIdentifier ?? "net.ainyan.promptrelay"
    private static let account = "prompt-relay-api-key"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, ObservableObject {
    @Published var deviceToken: String = ""
    @Published var connectionStatus: String = "未接続"
    @Published var connectionEnabled: Bool = {
        // UserDefaults に値がなければデフォルト true
        if UserDefaults.standard.object(forKey: "connectionEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "connectionEnabled")
    }()
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? AppConfig.defaultServerURL
    @Published var apiKey: String = {
        if let key = KeychainStore.read() { return key }
        let legacyKey = UserDefaults.standard.string(forKey: "apiKey") ?? ""
        if !legacyKey.isEmpty, KeychainStore.save(legacyKey) {
            UserDefaults.standard.removeObject(forKey: "apiKey")
        }
        return legacyKey
    }()

    private let registrationRefreshInterval: TimeInterval = 15 * 60
    private var lastSuccessfulRegistrationAt: Date?
    private var registrationInFlight = false
    private var pendingForcedRegistrationToken: String?
    private var registrationGeneration = 0

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        requestNotificationPermission(application)
        WatchBridge.shared.appDelegate = self
        WatchBridge.shared.activate()
        return true
    }

    // MARK: - Watch トークンの登録/解除 (iPhone が代行)

    /// 設定画面の通知音を、サーバへ申告する形 (通知種別 → ファイル名) にする。標準は申告しない。
    private var watchSoundDeclaration: [String: String] {
        var sounds: [String: String] = [:]
        if let f = NotificationSoundSettings.sound(for: .permissionRequest).fileName { sounds["permission_request"] = f }
        if let f = NotificationSoundSettings.sound(for: .completion).fileName { sounds["notification"] = f }
        return sounds
    }

    func registerWatchTokenWithServer() {
        let token = WatchBridge.shared.watchDeviceToken
        guard connectionEnabled, isApiKeyValid, !token.isEmpty,
              let url = URL(string: "\(serverURL)/register") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "token": token,
            "platform": "watchos",
            "sounds": watchSoundDeclaration,
        ])
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let result = error.map { "エラー: \($0.localizedDescription)" } ?? (code == 200 ? "登録済 (200)" : "HTTP \(code)")
            print("[PromptRelay] Watch token register → \(result)")
            WatchBridge.shared.notifyWatch(registerResult: result)
        }.resume()
    }

    private func unregisterWatchToken(serverURL: String, apiKey: String) {
        unregisterWatchToken(WatchBridge.shared.watchDeviceToken, serverURL: serverURL, apiKey: apiKey)
    }

    /// Watch のトークンが変わったとき、古いトークンをサーバから外す
    func unregisterStaleWatchToken(_ token: String) {
        unregisterWatchToken(token, serverURL: serverURL, apiKey: apiKey)
    }

    private func unregisterWatchToken(_ token: String, serverURL: String, apiKey: String) {
        guard (8...128).contains(apiKey.count), !serverURL.isEmpty, !token.isEmpty,
              let url = URL(string: "\(serverURL)/unregister") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    /// 通知音の設定変更時に呼ぶ (Watch 宛ての音はサーバ側で決まるため再申告が要る)
    func watchSoundSettingsChanged() {
        registerWatchTokenWithServer()
    }

    /// Watch 向けに、サーバの承認待ち一覧を取得して返す (未応答のみ、新しい順)。
    /// 返す形は Watch 側の WatchPendingRequest が通知の userInfo から作るものと揃える。
    func fetchPendingRequestsForWatch(completion: @escaping ([[String: Any]]?) -> Void) {
        guard connectionEnabled, isApiKeyValid, let url = URL(string: "\(serverURL)/permission-requests") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(nil)
                return
            }
            let pending = list
                .filter { $0["response"] == nil || $0["response"] is NSNull }
                .compactMap { r -> [String: Any]? in
                    guard let id = r["id"] as? String else { return nil }
                    let hostname = r["hostname"] as? String
                    return [
                        "request_id": id,
                        "title": hostname.map { "承認待ち [\($0)]" } ?? "承認待ち",
                        "body": r["message"] as? String ?? "",
                        "choices": r["choices"] as? [[String: Any]] ?? [],
                        "created_at": r["created_at"] as? Double ?? 0,
                    ]
                }
            print("[PromptRelay] pending requests for Watch: \(pending.count)")
            completion(pending)
        }.resume()
    }

    /// 承認応答の結果。gone はサーバ側で既に応答済み・期限切れ (別端末で回答した等)。
    enum ChoiceResponseOutcome {
        case sent
        case gone
        case failed
    }

    /// Watch からの承認応答を転送する
    func respondFromWatch(requestId: String, choice: Int, completion: ((ChoiceResponseOutcome) -> Void)?) {
        print("[PromptRelay] respond relayed from Watch: request=\(requestId) choice=\(choice)")
        // WCSession の delegate はバックグラウンドキューで呼ばれる。UIKit の背景実行枠は main で扱う。
        DispatchQueue.main.async {
            self.sendChoiceResponse(requestId: requestId, choice: choice, source: "watch", completion: completion)
        }
    }

    // MARK: - 通知カテゴリ登録（Approve/Deny アクション）
    private func registerNotificationCategories() {
        // フォールバック用カテゴリ（NotificationService Extension が動かなかった場合に使用）
        // 注意: setNotificationCategories は全カテゴリを上書きするため、
        // NSE が登録した動的カテゴリも含めて再登録する
        // 3選択肢パターン（Yes / Yes(以降スキップ) / No）
        let choice1 = UNNotificationAction(
            identifier: "CHOICE_1",
            title: "Yes",
            options: []
        )
        let choice2 = UNNotificationAction(
            identifier: "CHOICE_2",
            title: "Yes (以降スキップ)",
            options: []
        )
        let choice3 = UNNotificationAction(
            identifier: "CHOICE_3",
            title: "No",
            options: [.destructive]
        )

        let permissionCategory = UNNotificationCategory(
            identifier: "PERMISSION_REQUEST",
            actions: [choice1, choice2, choice3],
            intentIdentifiers: [],
            options: []
        )

        // 既存カテゴリ（NSE が登録した動的カテゴリ等）を保持しつつフォールバックを追加
        UNUserNotificationCenter.current().getNotificationCategories { existingCategories in
            var categories = existingCategories
            // PERMISSION_REQUEST は常に最新版で上書き
            categories = categories.filter { $0.identifier != "PERMISSION_REQUEST" }
            categories.insert(permissionCategory)
            UNUserNotificationCenter.current().setNotificationCategories(categories)
            print("[PromptRelay] Registered fallback category (total \(categories.count) categories)")
        }
    }

    // MARK: - 通知権限リクエスト
    private func requestNotificationPermission(_ application: UIApplication) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
            if let error = error {
                print("[PromptRelay] Notification permission error: \(error)")
            }
        }
    }

    // MARK: - デバイストークン取得成功
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        DispatchQueue.main.async {
            self.deviceToken = token
        }
#if DEBUG
        print("[PromptRelay] Device token: \(token.prefix(12))…")
#endif
        if connectionEnabled {
            registerTokenWithServer(token, force: true)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("[PromptRelay] Failed to register: \(error)")
        DispatchQueue.main.async {
            self.deviceToken = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: - ルームキーバリデーション
    var isApiKeyValid: Bool {
        apiKey.count >= 8 && apiKey.count <= 128
    }

    // MARK: - 認証ヘルパー
    func applyAuth(to request: inout URLRequest) {
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    // MARK: - 接続トグル制御
    func setConnectionEnabled(_ enabled: Bool) {
        guard connectionEnabled != enabled else { return }
        connectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "connectionEnabled")
        if enabled {
            guard !deviceToken.isEmpty, !deviceToken.hasPrefix("Error") else { return }
            registerTokenWithServer(deviceToken, force: true)
        } else {
            invalidateRegistration()
            // サーバからデバイストークンを解除（通知が届かなくなる）
            callUnregisterAPI()
            unregisterWatchToken(serverURL: serverURL, apiKey: apiKey)
            connectionStatus = "未接続"
        }
    }

    // MARK: - デバイストークン解除（fire and forget）
    private func callUnregisterAPI() {
        unregisterToken(deviceToken, serverURL: serverURL, apiKey: apiKey)
    }

    private func unregisterToken(_ token: String, serverURL: String, apiKey: String) {
        guard (8...128).contains(apiKey.count), !serverURL.isEmpty,
              !token.isEmpty, !token.hasPrefix("Error"),
              let url = URL(string: "\(serverURL)/unregister") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                guard let self,
                      self.connectionEnabled,
                      self.serverURL == serverURL,
                      self.apiKey == apiKey,
                      self.deviceToken == token else { return }
                // OFF直後に再度ONへ戻された場合は、遅れて完了した解除より後に
                // 登録を再実行し、サーバ側の最終状態を現在の設定へ収束させる。
                self.registerTokenWithServer(token, force: true)
            }
        }.resume()
    }

    private func invalidateRegistration() {
        registrationGeneration += 1
        registrationInFlight = false
        pendingForcedRegistrationToken = nil
        lastSuccessfulRegistrationAt = nil
    }

    // MARK: - ルームキー更新
    func updateApiKey(_ key: String) {
        guard apiKey != key else { return }
        if key.isEmpty {
            KeychainStore.remove()
        } else if !KeychainStore.save(key) {
            connectionStatus = "ルームキー保存エラー"
            return
        }

        let oldApiKey = apiKey
        let oldServerURL = serverURL
        let token = deviceToken
        invalidateRegistration()
        if connectionEnabled {
            unregisterToken(token, serverURL: oldServerURL, apiKey: oldApiKey)
        }

        if connectionEnabled {
            unregisterWatchToken(serverURL: oldServerURL, apiKey: oldApiKey)
        }

        apiKey = key
        UserDefaults.standard.removeObject(forKey: "apiKey")
        if connectionEnabled, !deviceToken.isEmpty, !deviceToken.hasPrefix("Error") {
            registerTokenWithServer(deviceToken, force: true)
        }
    }

    // MARK: - サーバにトークン登録
    func registerTokenWithServer(_ token: String, force: Bool = false) {
        guard connectionEnabled else { return }
        guard isApiKeyValid else {
            connectionStatus = "ルームキーエラー"
            return
        }
        guard let url = URL(string: "\(serverURL)/register") else { return }
        if registrationInFlight {
            if force { pendingForcedRegistrationToken = token }
            return
        }
        if !force, let lastSuccessfulRegistrationAt,
           Date().timeIntervalSince(lastSuccessfulRegistrationAt) < registrationRefreshInterval {
            return
        }
        registrationInFlight = true
        let generation = registrationGeneration
        let registrationServerURL = serverURL
        let registrationApiKey = apiKey

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                guard self.registrationGeneration == generation else {
                    // 設定変更や接続OFFより前の登録がサーバで完了していた場合も確実に解除する。
                    self.unregisterToken(token, serverURL: registrationServerURL, apiKey: registrationApiKey)
                    return
                }
                self.registrationInFlight = false
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        self.connectionStatus = "接続済み"
                        self.lastSuccessfulRegistrationAt = Date()
                        self.registerWatchTokenWithServer()
                    } else if httpResponse.statusCode == 401 {
                        self.connectionStatus = "認証エラー"
                        // 認証エラー → 接続トグルを自動 OFF
                        self.connectionEnabled = false
                        UserDefaults.standard.set(false, forKey: "connectionEnabled")
                        self.invalidateRegistration()
                    } else {
                        self.connectionStatus = "接続失敗: HTTP \(httpResponse.statusCode)"
                    }
                } else {
                    self.connectionStatus = "接続失敗: \(error?.localizedDescription ?? "Unknown")"
                }
                if self.connectionEnabled,
                   self.registrationGeneration == generation,
                   let pendingToken = self.pendingForcedRegistrationToken {
                    self.pendingForcedRegistrationToken = nil
                    self.registerTokenWithServer(pendingToken, force: true)
                }
            }
        }.resume()
    }

    // MARK: - フォアグラウンド復帰時のトークン再登録
    func reregisterTokenIfNeeded() {
        guard connectionEnabled, !deviceToken.isEmpty, !deviceToken.hasPrefix("Error") else { return }
        registerTokenWithServer(deviceToken)
    }

    // MARK: - フォアグラウンド通知表示
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // MARK: - 通知アクション応答処理
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let payloadRequestId = userInfo["request_id"] as? String
        let actionId = response.actionIdentifier
        let categoryId = response.notification.request.content.categoryIdentifier

        print("[PromptRelay] didReceive action=\(actionId) category=\(categoryId) requestId=\(payloadRequestId ?? "nil") serverURL=\(serverURL.isEmpty ? "(empty)" : "set")")

        // CHOICE_N 形式（動的カテゴリ・フォールバックカテゴリ共通）
        if actionId.hasPrefix("CHOICE_"), let choiceStr = actionId.split(separator: "_").last, let choiceNumber = Int(choiceStr) {
            if let id = payloadRequestId {
                sendChoiceResponse(requestId: id, choice: choiceNumber) { _ in completionHandler() }
                return
            } else {
                print("[PromptRelay] Warning: CHOICE action but no request_id in payload")
            }
        }

        completionHandler()
    }

    // MARK: - サーバに応答送信（選択肢番号ベース、リトライ付き）
    private func sendChoiceResponse(requestId: String, choice: Int, source: String = "notification", completion: ((ChoiceResponseOutcome) -> Void)? = nil) {
        // Cold launch 時に serverURL が空の場合、UserDefaults から再読み込み
        var effectiveURL = serverURL
        if effectiveURL.isEmpty {
            effectiveURL = UserDefaults.standard.string(forKey: "serverURL") ?? AppConfig.defaultServerURL
            print("[PromptRelay] serverURL was empty on sendChoiceResponse, re-read from UserDefaults: \(effectiveURL.isEmpty ? "(still empty)" : "ok")")
        }

        guard let url = URL(string: "\(effectiveURL)/permission-request/\(requestId)/respond") else {
            print("[PromptRelay] Invalid URL for respond: serverURL=\(effectiveURL) requestId=\(requestId)")
            completion?(.failed)
            return
        }

        print("[PromptRelay] sendChoiceResponse: request=\(requestId) choice=\(choice)")

        // バックグラウンド実行時間を確保（Apple Watch 応答時にプロセスが停止されるのを防ぐ）
        var backgroundTaskId = UIBackgroundTaskIdentifier.invalid
        var didFinish = false
        var outcome: ChoiceResponseOutcome = .failed
        let finish: () -> Void = {
            DispatchQueue.main.async {
                guard !didFinish else { return }
                didFinish = true
                completion?(outcome)
                if backgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTaskId)
                    backgroundTaskId = .invalid
                }
            }
        }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "sendChoiceResponse") {
            print("[PromptRelay] Background task expired for request=\(requestId)")
            finish()
        }

        sendWithRetry(url: url, choice: choice, source: source, attempt: 1, maxAttempts: 3) { statusCode in
            switch statusCode {
            case 200: outcome = .sent
            // 404 = not found / already responded: 別端末で回答済みか期限切れ。通知は消してよい
            case 404: outcome = .gone
            default: outcome = .failed
            }
            guard outcome != .failed else {
                print("[PromptRelay] Choice send failed after all retries: request=\(requestId) choice=\(choice) status=\(statusCode.map(String.init) ?? "none")")
                finish()
                return
            }
            // 通知削除の完了を待ってから背景実行枠を閉じる。Watch からの中継で
            // バックグラウンド起動された場合、先に閉じると削除前にプロセスが停止する。
            self.removeNotification(forRequestId: requestId) { _ in finish() }
        }
    }

    /// 完了時に HTTP ステータス (通信失敗は nil) を返す
    private func sendWithRetry(url: URL, choice: Int, source: String, attempt: Int, maxAttempts: Int, completion: @escaping (Int?) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        var body: [String: Any] = ["choice": choice, "source": source]
        if !deviceToken.isEmpty, !deviceToken.hasPrefix("Error") {
            body["device_token"] = deviceToken
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, httpResponse, error in
            if let error = error {
                print("[PromptRelay] Choice send attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    let delay = pow(2.0, Double(attempt - 1)) // 1秒, 2秒, 4秒...
                    DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                        self.sendWithRetry(url: url, choice: choice, source: source, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                    }
                } else {
                    completion(nil)
                }
            } else if let http = httpResponse as? HTTPURLResponse {
                print("[PromptRelay] Choice sent: \(choice) (HTTP \(http.statusCode), attempt \(attempt))")
                completion(http.statusCode)
            } else {
                completion(nil)
            }
        }.resume()
    }

    // MARK: - サーバURL更新
    func updateServerURL(_ url: String) {
        guard serverURL != url else { return }
        let oldServerURL = serverURL
        let oldApiKey = apiKey
        let token = deviceToken
        invalidateRegistration()
        if connectionEnabled {
            unregisterToken(token, serverURL: oldServerURL, apiKey: oldApiKey)
        }

        if connectionEnabled {
            unregisterWatchToken(serverURL: oldServerURL, apiKey: oldApiKey)
        }

        serverURL = url
        UserDefaults.standard.set(url, forKey: "serverURL")
        if connectionEnabled, !deviceToken.isEmpty, !deviceToken.hasPrefix("Error") {
            registerTokenWithServer(deviceToken, force: true)
        }
    }

    // MARK: - サイレントプッシュ受信
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let type = userInfo["type"] as? String, type == "dismiss",
              let requestId = userInfo["request_id"] as? String else {
            completionHandler(.noData)
            return
        }

        print("[PromptRelay] Silent push: dismiss request_id=\(requestId)")
        removeNotification(forRequestId: requestId) { removed in
            completionHandler(removed ? .newData : .noData)
        }
    }

    // MARK: - 通知削除ヘルパー
    private func removeNotification(forRequestId requestId: String, completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let idsToRemove = notifications
                .filter { $0.request.content.userInfo["request_id"] as? String == requestId }
                .map { $0.request.identifier }

            if !idsToRemove.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: idsToRemove)
                print("[PromptRelay] Removed \(idsToRemove.count) notification(s) for request_id=\(requestId)")
            }
            completion?(!idsToRemove.isEmpty)
        }
    }

    // MARK: - フォアグラウンドクリーンアップ（応答済み通知を一括削除）
    func cleanupStaleNotifications() {
        guard connectionEnabled, isApiKeyValid else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let permissionNotifications = notifications.filter {
                $0.request.content.userInfo["request_id"] is String
            }
            guard !permissionNotifications.isEmpty,
                  let url = URL(string: "\(self.serverURL)/permission-requests") else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            self.applyAuth(to: &request)
            request.timeoutInterval = 5

            URLSession.shared.dataTask(with: request) { data, _, error in
                guard let data, error == nil else { return }

                struct RequestStatus: Decodable {
                    let id: String
                    let response: String?
                }

                guard let statuses = try? JSONDecoder().decode([RequestStatus].self, from: data) else { return }
                let resolvedIds = Set(statuses.compactMap { $0.response != nil ? $0.id : nil })
                if resolvedIds.isEmpty { return }

                let idsToRemove = permissionNotifications.compactMap { notification -> String? in
                    guard let reqId = notification.request.content.userInfo["request_id"] as? String,
                          resolvedIds.contains(reqId) else { return nil }
                    return notification.request.identifier
                }
                if !idsToRemove.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: idsToRemove)
                    print("[PromptRelay] Cleanup: removed \(idsToRemove.count) stale notification(s)")
                }
            }.resume()
        }
    }
}
