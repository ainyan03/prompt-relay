import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let content = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        let userInfo = content.userInfo

        // 古い permission_request 通知を削除（新しい通知が最新のプロンプトなので古いものは不要）
        if userInfo["type"] as? String == "permission_request" {
            removeOldPermissionNotifications(
                currentRequestId: userInfo["request_id"] as? String,
                tmuxTarget: userInfo["tmux_target"] as? String
            )
        }

        // choices からリクエスト固有カテゴリを生成する。
        // カテゴリ識別子に request_id を含めることで、各通知が独自のボタンを保持する。
        // 古い通知を展開しても新しいリクエストのボタンに上書きされることがなくなる。
        // Watch は NSE を実行しないため PERMISSION_REQUEST（静的フォールバック）がそのまま使われる。
        guard let choicesData = userInfo["choices"] as? [[String: Any]],
              !choicesData.isEmpty,
              let requestId = userInfo["request_id"] as? String else {
            contentHandler(content)
            return
        }

        var actions: [UNNotificationAction] = []
        for choice in choicesData {
            guard let number = choice["number"] as? Int,
                  let text = choice["text"] as? String else { continue }

            let abbreviatedText = abbreviate(text)
            let lower = text.lowercased()
            let isDestructive = lower.hasPrefix("no") || lower.hasPrefix("reject") || lower.hasPrefix("deny")

            let action = UNNotificationAction(
                identifier: "CHOICE_\(number)",
                title: abbreviatedText,
                options: isDestructive ? [.destructive] : []
            )
            actions.append(action)
        }

        guard !actions.isEmpty else {
            contentHandler(content)
            return
        }

        // リクエスト固有カテゴリを作成（PERM_{request_id}）
        let categoryId = "PERM_\(requestId)"
        let requestCategory = UNNotificationCategory(
            identifier: categoryId,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        // カテゴリ識別子を差し替え（サーバからは PERMISSION_REQUEST で送られてくる）
        content.categoryIdentifier = categoryId

        UNUserNotificationCenter.current().getNotificationCategories { existingCategories in
            var categories = existingCategories
            // PERMISSION_REQUEST（フォールバック）は維持しつつ、固有カテゴリを追加
            // 古いリクエスト固有カテゴリが溜まるのを防ぐため、PERM_ プレフィックスの古いものを除去
            categories = categories.filter { !$0.identifier.hasPrefix("PERM_") || $0.identifier == categoryId }
            categories.insert(requestCategory)
            UNUserNotificationCenter.current().setNotificationCategories(categories)

            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let content = bestAttemptContent {
            contentHandler(content)
        }
    }

    // MARK: - 古い通知の削除

    private func removeOldPermissionNotifications(currentRequestId: String?, tmuxTarget: String?) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let idsToRemove = notifications
                .filter { notification in
                    let info = notification.request.content.userInfo
                    guard info["type"] as? String == "permission_request" else { return false }
                    // 今回の通知自体は残す
                    if let currentId = currentRequestId,
                       info["request_id"] as? String == currentId { return false }
                    // tmux_target が指定されている場合、同一ペインの通知のみ対象
                    if let target = tmuxTarget {
                        return info["tmux_target"] as? String == target
                    }
                    return true
                }
                .map { $0.request.identifier }

            if !idsToRemove.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: idsToRemove)
            }
        }
    }

    // MARK: - テキスト省略（Watch 向け）

    private func abbreviate(_ text: String) -> String {
        if text.count <= 25 {
            return text
        }

        // "Yes, and don't ask again for X in Y" → "Yes (以降スキップ)"
        if text.range(of: "don't ask again", options: .caseInsensitive) != nil
            || text.range(of: "don.t ask again", options: .caseInsensitive) != nil {
            return "Yes (以降スキップ)"
        }

        // "Yes, allow all edits in tmp/ during this session (shift+tab)" → "Yes (allow edits...)"
        if let range = text.range(of: "Yes, allow ", options: .caseInsensitive) {
            let rest = String(text[range.upperBound...])
            let truncated = rest.prefix(20)
            let cleaned = truncated.hasSuffix(" ") ? String(truncated.dropLast()) : String(truncated)
            return "Yes (\(cleaned)…)"
        }

        return String(text.prefix(22)) + "…"
    }
}
