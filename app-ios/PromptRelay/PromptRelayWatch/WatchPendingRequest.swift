import Foundation

/// Watch アプリの前面で応答するための、通知から取り出した承認リクエスト。
struct WatchPendingRequest: Identifiable, Equatable {
    struct Choice: Identifiable, Equatable {
        let number: Int
        let text: String
        var id: Int { number }
    }

    let id: String
    let title: String
    let body: String
    let choices: [Choice]
    /// 応答後に消すための通知識別子
    let notificationIdentifier: String

    /// 通知の userInfo と表示内容から組み立てる。choices 無しの旧形式は固定 3 択を補う。
    init?(userInfo: [AnyHashable: Any], title: String, body: String, notificationIdentifier: String) {
        guard let requestId = userInfo["request_id"] as? String else { return nil }
        let raw = userInfo["choices"] as? [[String: Any]] ?? []
        let parsedChoices = raw.compactMap { c -> Choice? in
            guard let number = c["number"] as? Int, let text = c["text"] as? String else { return nil }
            return Choice(number: number, text: text)
        }
        self.id = requestId
        self.title = title
        self.body = body
        self.choices = parsedChoices.isEmpty ? [
            Choice(number: 1, text: "Yes"),
            Choice(number: 2, text: "Yes (以降スキップ)"),
            Choice(number: 3, text: "No"),
        ] : parsedChoices
        self.notificationIdentifier = notificationIdentifier
    }

    /// iPhone 経由で取得した一覧の要素 (request_id / title / body / choices) から組み立てる。
    init?(listItem: [String: Any]) {
        guard let title = listItem["title"] as? String, let body = listItem["body"] as? String else { return nil }
        self.init(userInfo: listItem, title: title, body: body, notificationIdentifier: "")
    }

    /// 最後の選択肢 (No 相当) は破壊的表示にする (サーバの deny 判定と同じ規則)
    func isDestructive(_ choice: Choice) -> Bool {
        choice.number == choices.last?.number
    }
}
