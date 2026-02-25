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

        // choices から PERMISSION_REQUEST カテゴリのアクションを更新する。
        // categoryIdentifier は変更せず PERMISSION_REQUEST のまま維持する。
        // Watch は PERMISSION_REQUEST を起動時から知っているのでボタンは必ず出る。
        // アクション更新が間に合えば正しいテキスト、間に合わなければ静的フォールバック。
        guard let choicesData = userInfo["choices"] as? [[String: Any]],
              !choicesData.isEmpty else {
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

        // PERMISSION_REQUEST カテゴリ自体のアクションを更新（識別子は変更しない）
        let updatedCategory = UNNotificationCategory(
            identifier: "PERMISSION_REQUEST",
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().getNotificationCategories { existingCategories in
            var categories = existingCategories
            categories = categories.filter { $0.identifier != "PERMISSION_REQUEST" }
            categories.insert(updatedCategory)
            UNUserNotificationCenter.current().setNotificationCategories(categories)

            contentHandler(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let content = bestAttemptContent {
            contentHandler(content)
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
