import SwiftUI
import UserNotifications

struct ChoiceItem: Codable, Equatable {
    let number: Int
    let text: String

    var isDeny: Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("no") || lower.hasPrefix("reject") || lower.hasPrefix("deny")
    }
}

struct PermissionRequestItem: Identifiable, Codable, Equatable {
    let id: String
    let tool_name: String
    let message: String
    let created_at: Double
    let expires_at: Double?
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

    var expiresDate: Date {
        Date(timeIntervalSince1970: (expires_at ?? created_at + 120000) / 1000)
    }
}

private struct WebSocketUpdate: Decodable {
    let type: String
    let requests: [PermissionRequestItem]
}

class RequestsViewModel: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var requests: [PermissionRequestItem] = []
    @Published var isLoading = false

    private var webSocketSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectWorkItem: DispatchWorkItem?
    private var fallbackWorkItem: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var isRunning = false
    private var isWebSocketConnected = false
    private var isFetchInFlight = false
    private var stateGeneration = 0
    var serverURL: String = ""
    var apiKey: String = ""
    var deviceToken: String = ""

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func configure(serverURL: String, apiKey: String, deviceToken: String) {
        let changed = self.serverURL != serverURL || self.apiKey != apiKey
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.deviceToken = deviceToken
        if changed && isRunning {
            disconnectWebSocket()
            reconnectAttempt = 0
            fetch()
            connectWebSocket()
        }
    }

    func startUpdates() {
        guard !isRunning, !serverURL.isEmpty, (8...128).contains(apiKey.count) else { return }
        isRunning = true
        reconnectAttempt = 0
        fetch()
        connectWebSocket()
    }

    func stopUpdates() {
        isRunning = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        disconnectWebSocket()
    }

    func refresh() async {
        await withCheckedContinuation { continuation in
            fetch {
                continuation.resume()
            }
        }
    }

    private func webSocketURL() -> URL? {
        guard var components = URLComponents(string: serverURL),
              let scheme = components.scheme?.lowercased() else { return nil }
        switch scheme {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/ws" : "/\(basePath)/ws"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func connectWebSocket() {
        guard isRunning, webSocketTask == nil, let url = webSocketURL() else {
            scheduleFallbackFetch()
            return
        }

        var request = makeRequest(url: url)
        request.timeoutInterval = 10
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        webSocketSession = session
        webSocketTask = task
        task.resume()
        receiveNext(on: task)
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.isRunning, self.webSocketTask === task else { return }
                switch result {
                case .success(let message):
                    self.handleWebSocketMessage(message)
                    self.receiveNext(on: task)
                case .failure(let error):
                    print("[PromptRelay] WebSocket receive failed: \(error.localizedDescription)")
                    self.handleWebSocketDisconnect()
                }
            }
        }
    }

    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: return
        }
        guard let update = try? JSONDecoder().decode(WebSocketUpdate.self, from: data),
              update.type == "update" else { return }
        stateGeneration += 1
        applyRequests(update.requests)
    }

    private func handleWebSocketDisconnect() {
        disconnectWebSocket()
        scheduleReconnect()
        scheduleFallbackFetch()
    }

    private func disconnectWebSocket() {
        isWebSocketConnected = false
        let task = webSocketTask
        webSocketTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        webSocketSession?.invalidateAndCancel()
        webSocketSession = nil
    }

    private func scheduleReconnect() {
        guard isRunning, reconnectWorkItem == nil else { return }
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0)
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            self.connectWebSocket()
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleFallbackFetch() {
        guard isRunning, !isWebSocketConnected, fallbackWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.fallbackWorkItem = nil
            guard self.isRunning, !self.isWebSocketConnected else { return }
            self.fetch()
            self.scheduleFallbackFetch()
        }
        fallbackWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
    }

    func fetch(completion: (() -> Void)? = nil) {
        guard !isFetchInFlight,
              let url = URL(string: "\(serverURL)/permission-requests") else {
            completion?()
            return
        }
        isFetchInFlight = true
        isLoading = true
        let generationAtStart = stateGeneration

        var request = makeRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, error in
            let items = data.flatMap { try? JSONDecoder().decode([PermissionRequestItem].self, from: $0) }
            DispatchQueue.main.async {
                self.isFetchInFlight = false
                self.isLoading = false
                // HTTP開始後にWebSocket更新を受けていた場合、古い応答で上書きしない。
                if error == nil, let items, self.stateGeneration == generationAtStart {
                    self.applyRequests(items)
                }
                completion?()
            }
        }.resume()
    }

    private func applyRequests(_ items: [PermissionRequestItem]) {
        guard items != requests else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            requests = items
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        DispatchQueue.main.async {
            guard self.isRunning, self.webSocketTask === webSocketTask else { return }
            self.isWebSocketConnected = true
            self.reconnectAttempt = 0
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.fallbackWorkItem?.cancel()
            self.fallbackWorkItem = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        DispatchQueue.main.async {
            guard self.isRunning, self.webSocketTask === webSocketTask else { return }
            self.handleWebSocketDisconnect()
        }
    }

    private func postJSON(url: URL, body: [String: Any], requestId: String) {
        var request = makeRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        var requestBody = body
        if !deviceToken.isEmpty, !deviceToken.hasPrefix("Error") {
            requestBody["device_token"] = deviceToken
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let succeeded = (response as? HTTPURLResponse)?.statusCode == 200
            if let error = error {
                print("[PromptRelay] POST failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("[PromptRelay] POST error: HTTP \(http.statusCode)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if succeeded {
                    self.removeDeliveredNotification(requestId: requestId)
                }
                if !self.isWebSocketConnected {
                    self.fetch()
                }
            }
        }.resume()
    }

    func respondWithChoice(id: String, choice: Int) {
        guard let url = URL(string: "\(serverURL)/permission-request/\(id)/respond") else { return }
        postJSON(url: url, body: ["choice": choice, "source": "ios-app"], requestId: id)
    }

    // レガシー（choices がない場合のフォールバック）
    func respond(id: String, response: String) {
        guard let url = URL(string: "\(serverURL)/permission-request/\(id)/respond") else { return }
        postJSON(url: url, body: ["response": response, "source": "ios-app"], requestId: id)
    }

    private func removeDeliveredNotification(requestId: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let identifiers = notifications.compactMap { notification -> String? in
                guard notification.request.content.userInfo["request_id"] as? String == requestId else {
                    return nil
                }
                return notification.request.identifier
            }
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        }
    }
}

struct RequestsView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var viewModel = RequestsViewModel()
    @Environment(\.scenePhase) private var scenePhase
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
        .refreshable {
            await viewModel.refresh()
        }
        .onAppear {
            viewModel.configure(
                serverURL: appDelegate.serverURL,
                apiKey: appDelegate.apiKey,
                deviceToken: appDelegate.deviceToken
            )
            if scenePhase == .active && appDelegate.connectionEnabled {
                viewModel.startUpdates()
            }
        }
        .onDisappear {
            viewModel.stopUpdates()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active && appDelegate.connectionEnabled {
                viewModel.configure(
                    serverURL: appDelegate.serverURL,
                    apiKey: appDelegate.apiKey,
                    deviceToken: appDelegate.deviceToken
                )
                viewModel.startUpdates()
            } else {
                viewModel.stopUpdates()
            }
        }
        .onChange(of: appDelegate.deviceToken) { newToken in
            viewModel.configure(
                serverURL: appDelegate.serverURL,
                apiKey: appDelegate.apiKey,
                deviceToken: newToken
            )
        }
        .onChange(of: appDelegate.connectionEnabled) { enabled in
            if enabled && scenePhase == .active {
                viewModel.configure(
                    serverURL: appDelegate.serverURL,
                    apiKey: appDelegate.apiKey,
                    deviceToken: appDelegate.deviceToken
                )
                viewModel.startUpdates()
            } else {
                viewModel.stopUpdates()
            }
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
                        let remaining = max(0, Int(item.expiresDate.timeIntervalSince(context.date)))
                        Text("残り\(remaining)秒")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(remaining <= 30 ? .red : remaining <= 60 ? .yellow : .secondary)
                    }
                } else {
                    Text(item.createdDate, style: .relative)
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
}
