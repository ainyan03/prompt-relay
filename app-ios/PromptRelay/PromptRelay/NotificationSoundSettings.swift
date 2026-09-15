import Foundation
import UserNotifications

// 通知音の選択肢と、その保存先。
// メインアプリ (設定画面) と NotificationService 拡張の両方から使うため、
// 保存先は App Group の共有 UserDefaults にする (拡張は本体の UserDefaults.standard を読めない)。
// 音声ファイルは本体アプリの bundle に同梱する (通知の再生時に本体 bundle から探される)。
// ファイルの再生成は app-ios/tools/gen-sounds.py。

enum NotificationSound: String, CaseIterable, Identifiable {
    case system = "default"
    case chime
    case bell
    case pop
    case triple
    case marimba
    case pulse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "標準"
        case .chime: return "チャイム"
        case .bell: return "ベル"
        case .pop: return "ポップ"
        case .triple: return "トリプル"
        case .marimba: return "マリンバ"
        case .pulse: return "パルス"
        }
    }

    /// bundle 内のファイル名。標準音は nil。
    var fileName: String? {
        self == .system ? nil : "\(rawValue).caf"
    }

    var notificationSound: UNNotificationSound {
        guard let fileName else { return .default }
        return UNNotificationSound(named: UNNotificationSoundName(fileName))
    }
}

/// 通知の状況。サーバのペイロード `type` で判定する。
enum NotificationSituation: String, CaseIterable, Identifiable {
    /// 承認リクエスト (type == "permission_request")
    case permissionRequest
    /// 処理完了・Codex goal 等の情報通知 (それ以外)
    case completion

    var id: String { rawValue }

    var label: String {
        switch self {
        case .permissionRequest: return "承認リクエスト"
        case .completion: return "完了通知"
        }
    }

    var defaultsKey: String {
        switch self {
        case .permissionRequest: return "notificationSound.permissionRequest"
        case .completion: return "notificationSound.completion"
        }
    }

    static func from(userInfo: [AnyHashable: Any]) -> NotificationSituation {
        (userInfo["type"] as? String) == "permission_request" ? .permissionRequest : .completion
    }
}

enum NotificationSoundSettings {
    /// App Group ID。Info.plist の PRAppGroupId (= group.$(BUNDLE_ID_PREFIX)) から取る。
    static var appGroupId: String? {
        Bundle.main.object(forInfoDictionaryKey: "PRAppGroupId") as? String
    }

    static var sharedDefaults: UserDefaults? {
        guard let appGroupId else { return nil }
        return UserDefaults(suiteName: appGroupId)
    }

    static func sound(for situation: NotificationSituation) -> NotificationSound {
        guard let raw = sharedDefaults?.string(forKey: situation.defaultsKey),
              let sound = NotificationSound(rawValue: raw) else { return .system }
        return sound
    }

    static func setSound(_ sound: NotificationSound, for situation: NotificationSituation) {
        sharedDefaults?.set(sound.rawValue, forKey: situation.defaultsKey)
    }
}
