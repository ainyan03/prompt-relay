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

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerNotificationCategories()
        requestNotificationPermission(application)
        return true
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
        connectionEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "connectionEnabled")
        if enabled {
            guard !deviceToken.isEmpty, !deviceToken.hasPrefix("Error") else { return }
            registerTokenWithServer(deviceToken, force: true)
        } else {
            // サーバからデバイストークンを解除（通知が届かなくなる）
            callUnregisterAPI()
            connectionStatus = "未接続"
        }
    }

    // MARK: - デバイストークン解除（fire and forget）
    private func callUnregisterAPI() {
        guard isApiKeyValid, !serverURL.isEmpty, !deviceToken.isEmpty, !deviceToken.hasPrefix("Error"),
              let url = URL(string: "\(serverURL)/unregister") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": deviceToken])
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: - ルームキー更新
    func updateApiKey(_ key: String) {
        apiKey = key
        if key.isEmpty {
            KeychainStore.remove()
        } else if !KeychainStore.save(key) {
            connectionStatus = "ルームキー保存エラー"
            return
        }
        UserDefaults.standard.removeObject(forKey: "apiKey")
        if connectionEnabled, !deviceToken.isEmpty, !deviceToken.hasPrefix("Error") {
            registerTokenWithServer(deviceToken, force: true)
        }
    }

    // MARK: - サーバにトークン登録
    func registerTokenWithServer(_ token: String, force: Bool = false) {
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                self.registrationInFlight = false
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        self.connectionStatus = "接続済み"
                        self.lastSuccessfulRegistrationAt = Date()
                    } else if httpResponse.statusCode == 401 {
                        self.connectionStatus = "認証エラー"
                        // 認証エラー → 接続トグルを自動 OFF
                        self.connectionEnabled = false
                        UserDefaults.standard.set(false, forKey: "connectionEnabled")
                    } else {
                        self.connectionStatus = "接続失敗: HTTP \(httpResponse.statusCode)"
                    }
                } else {
                    self.connectionStatus = "接続失敗: \(error?.localizedDescription ?? "Unknown")"
                }
                if let pendingToken = self.pendingForcedRegistrationToken {
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
                sendChoiceResponse(requestId: id, choice: choiceNumber, completion: completionHandler)
                return
            } else {
                print("[PromptRelay] Warning: CHOICE action but no request_id in payload")
            }
        }

        completionHandler()
    }

    // MARK: - サーバに応答送信（選択肢番号ベース、リトライ付き）
    private func sendChoiceResponse(requestId: String, choice: Int, completion: (() -> Void)? = nil) {
        // Cold launch 時に serverURL が空の場合、UserDefaults から再読み込み
        var effectiveURL = serverURL
        if effectiveURL.isEmpty {
            effectiveURL = UserDefaults.standard.string(forKey: "serverURL") ?? AppConfig.defaultServerURL
            print("[PromptRelay] serverURL was empty on sendChoiceResponse, re-read from UserDefaults: \(effectiveURL.isEmpty ? "(still empty)" : "ok")")
        }

        guard let url = URL(string: "\(effectiveURL)/permission-request/\(requestId)/respond") else {
            print("[PromptRelay] Invalid URL for respond: serverURL=\(effectiveURL) requestId=\(requestId)")
            completion?()
            return
        }

        print("[PromptRelay] sendChoiceResponse: request=\(requestId) choice=\(choice)")

        // バックグラウンド実行時間を確保（Apple Watch 応答時にプロセスが停止されるのを防ぐ）
        var backgroundTaskId = UIBackgroundTaskIdentifier.invalid
        var didFinish = false
        let finish: () -> Void = {
            DispatchQueue.main.async {
                guard !didFinish else { return }
                didFinish = true
                completion?()
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

        sendWithRetry(url: url, choice: choice, attempt: 1, maxAttempts: 3) { success in
            if !success {
                print("[PromptRelay] Choice send failed after all retries: request=\(requestId) choice=\(choice)")
            } else {
                self.removeNotification(forRequestId: requestId)
            }
            finish()
        }
    }

    private func sendWithRetry(url: URL, choice: Int, attempt: Int, maxAttempts: Int, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        var body: [String: Any] = ["choice": choice, "source": "notification"]
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
                        self.sendWithRetry(url: url, choice: choice, attempt: attempt + 1, maxAttempts: maxAttempts, completion: completion)
                    }
                } else {
                    completion(false)
                }
            } else if let http = httpResponse as? HTTPURLResponse {
                print("[PromptRelay] Choice sent: \(choice) (HTTP \(http.statusCode), attempt \(attempt))")
                completion(http.statusCode == 200)
            } else {
                completion(false)
            }
        }.resume()
    }

    // MARK: - サーバURL更新
    func updateServerURL(_ url: String) {
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
