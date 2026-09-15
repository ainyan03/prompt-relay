import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        TabView {
            NavigationStack {
                RequestsView()
            }
            .tabItem {
                Label("リクエスト", systemImage: "bell.badge")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("設定", systemImage: "gear")
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var editURL: String = ""
    @State private var editApiKey: String = ""
    @State private var urlSaveTimer: Timer? = nil
    @State private var apiKeySaveTimer: Timer? = nil
    @State private var permissionSound: NotificationSound = NotificationSoundSettings.sound(for: .permissionRequest)
    @State private var completionSound: NotificationSound = NotificationSoundSettings.sound(for: .completion)
    @State private var previewPlayer: AVAudioPlayer? = nil

    var body: some View {
        List {
            // ステータス
            Section("ステータス") {
                LabeledContent("接続") {
                    Text(appDelegate.connectionStatus)
                        .foregroundColor(statusColor)
                }
                Text(appDelegate.deviceToken.isEmpty ? "取得中..." : appDelegate.deviceToken)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            // 接続設定
            Section("接続設定") {
                TextField("http://192.168.x.x:3939", text: $editURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: editURL) { newValue in
                        urlSaveTimer?.invalidate()
                        urlSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            DispatchQueue.main.async {
                                appDelegate.updateServerURL(newValue)
                            }
                        }
                    }
                SecureField("ルームキー (任意の文字列, 8〜128文字)", text: $editApiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: editApiKey) { newValue in
                        apiKeySaveTimer?.invalidate()
                        apiKeySaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                            DispatchQueue.main.async {
                                appDelegate.updateApiKey(newValue)
                            }
                        }
                    }
                if let error = apiKeyValidationError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Toggle("接続", isOn: Binding(
                    get: { appDelegate.connectionEnabled },
                    set: { newValue in
                        if newValue, apiKeyValidationError != nil {
                            return
                        }
                        appDelegate.setConnectionEnabled(newValue)
                    }
                ))
                if isErrorStatus {
                    Text(appDelegate.connectionStatus)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // 通知音 (状況別)。選択時に試聴する。
            Section {
                Picker("承認リクエスト", selection: $permissionSound) {
                    ForEach(NotificationSound.allCases) { sound in
                        Text(sound.label).tag(sound)
                    }
                }
                .onChange(of: permissionSound) { newValue in
                    NotificationSoundSettings.setSound(newValue, for: .permissionRequest)
                    playPreview(newValue)
                }
                Picker("完了通知", selection: $completionSound) {
                    ForEach(NotificationSound.allCases) { sound in
                        Text(sound.label).tag(sound)
                    }
                }
                .onChange(of: completionSound) { newValue in
                    NotificationSoundSettings.setSound(newValue, for: .completion)
                    playPreview(newValue)
                }
            } header: {
                Text("通知音")
            } footer: {
                Text("選ぶと試聴できます（消音スイッチ ON では鳴りません）。Apple Watch では標準音になります。")
            }
        }
        .navigationTitle("設定")
        .onAppear {
            editURL = appDelegate.serverURL
            editApiKey = appDelegate.apiKey
        }
    }

    private func playPreview(_ sound: NotificationSound) {
        previewPlayer?.stop()
        guard let fileName = sound.fileName,
              let url = Bundle.main.url(forResource: fileName, withExtension: nil) else { return }
        previewPlayer = try? AVAudioPlayer(contentsOf: url)
        previewPlayer?.play()
    }

    private var statusColor: Color {
        switch appDelegate.connectionStatus {
        case "接続済み": return .green
        case let s where s.hasPrefix("認証") || s.hasPrefix("接続失敗") || s.hasPrefix("ルームキー"): return .red
        default: return .orange
        }
    }

    private var isErrorStatus: Bool {
        appDelegate.connectionStatus.hasPrefix("認証") || appDelegate.connectionStatus.hasPrefix("接続失敗") || appDelegate.connectionStatus.hasPrefix("ルームキー")
    }

    private var apiKeyValidationError: String? {
        let key = editApiKey
        if key.isEmpty { return "ルームキーを入力してください" }
        if key.count < 8 { return "ルームキーは 8 文字以上で入力してください (\(key.count)文字)" }
        if key.count > 128 { return "ルームキーは 128 文字以下で入力してください" }
        return nil
    }
}
