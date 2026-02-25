import SwiftUI

struct ChoiceItem: Codable {
    let number: Int
    let text: String

    var isDeny: Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("no") || lower.hasPrefix("reject") || lower.hasPrefix("deny")
    }
}

struct PermissionRequestItem: Identifiable, Codable {
    let id: String
    let tool_name: String
    let message: String
    let created_at: Double
    let choices: [ChoiceItem]?
    var response: String?
    var responded_at: Double?
    var send_key: String?
    var hostname: String?

    var isPending: Bool { response == nil }
    var isCancelled: Bool { response == "cancelled" }
    var isExpired: Bool { response == "expired" }

    var createdDate: Date {
        Date(timeIntervalSince1970: created_at / 1000)
    }
}

class RequestsViewModel: ObservableObject {
    @Published var requests: [PermissionRequestItem] = []
    @Published var isLoading = false

    private var timer: Timer?
    var serverURL: String = ""
    var apiKey: String = ""

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func startPolling() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.fetch()
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func fetch() {
        guard let url = URL(string: "\(serverURL)/permission-requests") else { return }

        let request = makeRequest(url: url)
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil else { return }
            if let items = try? JSONDecoder().decode([PermissionRequestItem].self, from: data) {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        self.requests = items
                    }
                }
            }
        }.resume()
    }

    private func postJSON(url: URL, body: [String: Any]) {
        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                print("[PromptRelay] POST failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("[PromptRelay] POST error: HTTP \(http.statusCode)")
            }
            DispatchQueue.main.async {
                self?.fetch()
            }
        }.resume()
    }

    func respondWithChoice(id: String, choice: Int) {
        guard let url = URL(string: "\(serverURL)/permission-request/\(id)/respond") else { return }
        postJSON(url: url, body: ["choice": choice, "source": "ios-app"])
    }

    // レガシー（choices がない場合のフォールバック）
    func respond(id: String, response: String) {
        guard let url = URL(string: "\(serverURL)/permission-request/\(id)/respond") else { return }
        postJSON(url: url, body: ["response": response, "source": "ios-app"])
    }
}

struct RequestsView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var viewModel = RequestsViewModel()
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var knownPendingIds: Set<String> = []
    @State private var buttonsLocked = false
    @State private var lockGeneration = 0

    var body: some View {
        let pending = viewModel.requests.filter { $0.isPending }
        let responded = viewModel.requests.filter { !$0.isPending }
        let isLandscape = verticalSizeClass == .compact

        Group {
            if pending.isEmpty && responded.isEmpty {
                VStack {
                    Spacer()
                    Text("リクエストなし")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if isLandscape {
                // 横向き: 左に承認待ち、右に履歴
                HStack(spacing: 0) {
                    if !pending.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("承認待ち")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal)
                                    .padding(.top, 8)
                                    .padding(.bottom, 4)

                                ForEach(pending) { item in
                                    RequestRow(item: item, viewModel: viewModel, isLocked: buttonsLocked)
                                        .padding(.horizontal)
                                        .padding(.vertical, 4)
                                        .transition(.asymmetric(
                                            insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity
                                        ))
                                    if item.id != pending.last?.id {
                                        Divider().padding(.leading)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)

                        Divider()
                    }

                    List {
                        Section(header: Text("履歴")) {
                            ForEach(responded) { item in
                                RequestRow(item: item, viewModel: nil)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .frame(maxWidth: .infinity)
                }
            } else {
                // 縦向き: 上に承認待ち固定、下に履歴スクロール
                VStack(spacing: 0) {
                    if !pending.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("承認待ち")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal)
                                .padding(.top, 8)
                                .padding(.bottom, 4)

                            ForEach(pending) { item in
                                RequestRow(item: item, viewModel: viewModel, isLocked: buttonsLocked)
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                                if item.id != pending.last?.id {
                                    Divider().padding(.leading)
                                }
                            }
                        }

                        Divider()
                    }

                    List {
                        Section(header: Text("履歴")) {
                            ForEach(responded) { item in
                                RequestRow(item: item, viewModel: nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
        }
        .navigationTitle("リクエスト")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.serverURL = appDelegate.serverURL
            viewModel.apiKey = appDelegate.apiKey
            viewModel.startPolling()
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .onChange(of: pending.map(\.id)) { newPendingIds in
            let newIdSet = Set(newPendingIds)
            let hasNew = newPendingIds.contains(where: { !knownPendingIds.contains($0) })
            if hasNew && !knownPendingIds.isEmpty {
                buttonsLocked = true
                lockGeneration += 1
                let gen = lockGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if lockGeneration == gen {
                        buttonsLocked = false
                    }
                }
            }
            knownPendingIds = newIdSet
        }
    }
}

struct RequestRow: View {
    let item: PermissionRequestItem
    let viewModel: RequestsViewModel?
    var isLocked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.tool_name)
                    .font(.headline)
                    .lineLimit(1)
                if let hostname = item.hostname {
                    Text(hostname)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                Spacer()
                if item.isPending {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(item.createdDate.addingTimeInterval(120).timeIntervalSince(context.date)))
                        Text("残り\(remaining)秒")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(remaining <= 30 ? .red : remaining <= 60 ? .yellow : .secondary)
                    }
                } else {
                    Text(timeAgo(item.createdDate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Text(item.message)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(6)
                .foregroundColor(.secondary)

            if item.isCancelled {
                HStack {
                    Image(systemName: "arrow.uturn.left.circle.fill")
                        .foregroundColor(.secondary)
                    Text("Cancelled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if item.isExpired {
                HStack {
                    Image(systemName: "clock.badge.xmark.fill")
                        .foregroundColor(.yellow)
                    Text("Expired")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
            } else if item.response != nil {
                HStack {
                    // send_key と choices から選んだ選択肢を特定し、テキスト内容で色・アイコンを決定
                    let chosen: ChoiceItem? = {
                        guard let sendKey = item.send_key,
                              let keyNum = Int(sendKey),
                              let choices = item.choices else { return nil }
                        return choices.first(where: { $0.number == keyNum })
                    }()
                    let isDeny = chosen?.isDeny ?? (item.response == "deny")
                    Image(systemName: isDeny ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(isDeny ? .red : .green)
                    if let chosen = chosen {
                        Text(chosen.text)
                            .font(.caption)
                            .foregroundColor(isDeny ? .red : .green)
                            .lineLimit(2)
                    }
                }
            } else if let vm = viewModel {
                choiceButtons(vm: vm)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func choiceButtons(vm: RequestsViewModel) -> some View {
        if let choices = item.choices, !choices.isEmpty {
            // 動的ボタン: choices に基づく
            VStack(spacing: 12) {
                ForEach(choices, id: \.number) { choice in
                    Button(action: {
                        vm.respondWithChoice(id: item.id, choice: choice.number)
                    }) {
                        Text("\(choice.number). \(choice.text)")
                            .lineLimit(2)
                            .font(.subheadline)
                            .foregroundColor(choice.isDeny ? .white : .black)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(choice.isDeny ? .red : .green)
                    .disabled(isLocked)
                }
            }
        } else {
            // フォールバック: 固定ボタン
            HStack(spacing: 12) {
                Button(action: { vm.respond(id: item.id, response: "allow") }) {
                    Label("Approve", systemImage: "checkmark")
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isLocked)

                Button(action: { vm.respond(id: item.id, response: "deny") }) {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isLocked)
            }
        }
    }

    private func timeAgo(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "\(seconds)秒前" }
        if seconds < 3600 { return "\(seconds / 60)分前" }
        return "\(seconds / 3600)時間前"
    }
}
