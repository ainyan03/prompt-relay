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

    /// 通知の userInfo と表示内容から組み立てる。承認リクエスト以外 (choices 無し) は nil。
    init?(userInfo: [AnyHashable: Any], title: String, body: String, notificationIdentifier: String) {
        guard let requestId = userInfo["request_id"] as? String,
              let raw = userInfo["choices"] as? [[String: Any]], !raw.isEmpty else { return nil }
        let choices = raw.compactMap { c -> Choice? in
            guard let number = c["number"] as? Int, let text = c["text"] as? String else { return nil }
            return Choice(number: number, text: text)
        }
        guard !choices.isEmpty else { return nil }
        self.id = requestId
        self.title = title
        self.body = body
        self.choices = choices
        self.notificationIdentifier = notificationIdentifier
    }

    /// 最後の選択肢 (No 相当) は破壊的表示にする (サーバの deny 判定と同じ規則)
    func isDestructive(_ choice: Choice) -> Bool {
        choice.number == choices.last?.number
    }
}
