import AppKit
import ApplicationServices
import Darwin
import Foundation
import Network

/// 로컬 웹서버(HTTP + WebSocket). 아이폰 사파리가 접속하면 트랙패드 UI를 내려주고,
/// WebSocket 으로 받은 명령을 `EventInjector` 로 넘긴다.
final class HelperServer: ObservableObject {
    @Published var isRunning = false
    @Published var httpURL = ""
    @Published var ipFallback = ""
    @Published var tailscaleURL = ""   // 외부(다른 네트워크·셀룰러)에서도 되는 고정 주소
    @Published var activeClients = 0
    @Published var accessibilityGranted = false

    // 진단용: 아이폰에서 명령이 실제로 도착하는지 확인
    @Published var commandCount = 0
    @Published var lastCommand = "-"

    // 선택적 PIN 페어링(같은 Wi-Fi의 타인 접속 차단)
    @Published var pairingEnabled = false
    @Published var pairingPin = ""

    let port: UInt16 = 8765

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPWebSocketConnection] = [:]
    private var upgradedKeys: Set<ObjectIdentifier> = []
    private var accessibilityTimer: Timer?

    // 연결 장부는 전용 직렬 큐에서만 다룬다(메인 스레드 분리 → 다수 동시접속에도 응답 안 밀림)
    private let serverQueue = DispatchQueue(label: "com.joonlab.macpilot.server")
    private let maxConnections = 256   // 폭주(포트 스캐너 등) 시 FD 고갈 방지용 상한
    private let pairing = Pairing()    // 선택적 PIN 페어링(기본 off)

    init() {
        HelperServer.raiseFileDescriptorLimit()
        resetLog()
        start()
        refreshAccessibility()
        // 권한 상태가 항상 최신으로 보이도록 주기적으로 갱신
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshAccessibility()
            self?.updateTailscaleURL()   // Tailscale 은 나중에 붙을 수 있어 주기적으로 갱신
        }
        // 앱 목록(아이콘 렌더)을 시작 직후 1회 미리 빌드→캐시. 이후 getApps 는 메인 블록 없이 즉시 응답.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = AppList.json() }
        // 페어링 상태를 UI 로 미러
        pairingEnabled = pairing.enabled
        pairingPin = pairing.pin
    }

    // MARK: - PIN 페어링

    func setPairing(_ on: Bool) {
        pairing.setEnabled(on)
        pairingEnabled = on
        if on { closeAllConnections() }   // 켜는 순간 기존 연결을 끊어 재페어링 강제
    }

    func regeneratePairingPin() {
        pairing.regeneratePin()
        pairingPin = pairing.pin
        closeAllConnections()             // PIN 변경 → 기존 쿠키 무효 → 끊어서 재페어링
    }

    private func closeAllConnections() {
        serverQueue.async { [weak self] in
            guard let self else { return }
            for c in self.connections.values { c.forceClose() }
        }
    }

    /// 프로세스 파일 디스크립터 소프트 한도를 올린다(기본값이 낮으면 다수 동시접속 때 소켓 고갈 → 흰 화면).
    private static func raiseFileDescriptorLimit() {
        var lim = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &lim) == 0 else { return }
        let target: rlim_t = 4096
        if lim.rlim_cur < target {
            lim.rlim_cur = min(target, lim.rlim_max)
            _ = setrlimit(RLIMIT_NOFILE, &lim)
        }
    }

    func start() {
        do {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            // TCP_NODELAY: Nagle 이 소형 WS 프레임(move)을 묶어 보내면 커서가 덩어리져 보인다.
            // 체감 지연·부드러움에 가장 큰 영향을 주는 설정.
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 30
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.serviceClass = .responsiveData   // 인터랙티브 트래픽 우선순위
            let listener = try NWListener(using: params, on: nwPort)

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.updateURL()
                    case .failed, .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)   // 메인 X — 전용 큐에서 처리
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            print("[HelperServer] 리스너 시작 실패(포트 \(port) 사용 중일 수 있음): \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = HTTPWebSocketConnection(connection: connection, pairing: pairing)
        let key = ObjectIdentifier(client)

        client.onCommand = { [weak self, weak client] command in
            self?.handleCommand(command, client: client)
        }
        client.onUpgrade = { [weak self] in
            guard let self else { return }
            self.serverQueue.async { [weak self] in
                guard let self else { return }
                self.upgradedKeys.insert(key)
                let n = self.upgradedKeys.count
                DispatchQueue.main.async { [weak self] in self?.activeClients = n }
            }
        }
        client.onClose = { [weak self, weak client] in
            EventInjector.releaseAll()  // 드래그 중 연결이 끊겨도 버튼이 눌린 채 남지 않도록
            if #available(macOS 14.0, *), let client { ScreenStreamer.shared.removeViewer(client) }  // 미러 뷰어 해제
            guard let self else { return }
            self.serverQueue.async { [weak self] in
                guard let self else { return }
                self.connections[key] = nil
                self.upgradedKeys.remove(key)
                let n = self.upgradedKeys.count
                DispatchQueue.main.async { [weak self] in self?.activeClients = n }
            }
        }

        // 연결 등록·시작은 전용 큐에서. 동시연결 상한 초과 시 새 연결 거절(폭주 방어).
        serverQueue.async { [weak self] in
            guard let self else { connection.cancel(); return }
            if self.connections.count >= self.maxConnections {
                connection.cancel()
                return
            }
            self.connections[key] = client
            client.start()
        }
    }

    /// WebSocket 으로 들어온 명령 처리. move/scroll(고빈도)은 메인 UI 갱신을 건너뛰고 주입만 한다.
    private func handleCommand(_ command: InboundCommand, client: HTTPWebSocketConnection?) {
        switch command.t {
        case "getDeck":
            let json = DeckStore.loadString() ?? "null"
            client?.sendText("{\"t\":\"deck\",\"json\":\(json)}")
            return
        case "saveDeck":
            if let json = command.deckJson { DeckStore.save(json) }
            return
        case "getApps":
            // 캐시 준비됐으면 즉시(오프메인) 응답. 아직이면 main 에서 1회 빌드(드문 경우).
            if let cached = AppList.cachedJSONIfReady() {
                client?.sendText("{\"t\":\"apps\",\"list\":\(cached)}")
            } else {
                DispatchQueue.main.async {
                    client?.sendText("{\"t\":\"apps\",\"list\":\(AppList.json())}")
                }
            }
            return
        case "mirror":
            // 맥 화면 실시간 미러링 (뷰어 등록/해제/적응 파라미터/디스플레이 선택)
            guard #available(macOS 14.0, *), let client else { return }
            switch command.action {
            case "start":
                if let d = command.display { ScreenStreamer.shared.selectDisplay(CGDirectDisplayID(d), requester: client) }
                ScreenStreamer.shared.addViewer(client)
            case "stop":     ScreenStreamer.shared.removeViewer(client)
            case "config":   ScreenStreamer.shared.configure(longEdge: command.w, fps: command.fps, quality: command.q)
            case "displays": ScreenStreamer.shared.sendDisplays(to: client)
            case "select":   ScreenStreamer.shared.selectDisplay(command.display.map { CGDirectDisplayID($0) }, requester: client)
            default: break
            }
            return
        default:
            break
        }
        let t = command.t
        if t != "move", t != "scroll" {
            logCommand(command)
            DispatchQueue.main.async { [weak self] in
                self?.commandCount += 1
                self?.lastCommand = command.dir.map { "\(t):\($0)" } ?? t
            }
        }
        EventInjector.perform(command)
    }

    private func updateURL() {
        // .local 고정 주소 우선 (IP가 바뀌어도 안 변함)
        if let host = NetworkInfo.localHostName() {
            httpURL = "http://\(host):\(port)"
        } else if let ip = NetworkInfo.primaryIPv4() {
            httpURL = "http://\(ip):\(port)"
        } else {
            httpURL = "http://localhost:\(port)"
        }
        // IP 폴백 (mDNS 안 될 때용)
        if let ip = NetworkInfo.primaryIPv4() {
            ipFallback = "또는 http://\(ip):\(port)"
        } else {
            ipFallback = ""
        }
        updateTailscaleURL()
    }

    private func updateTailscaleURL() {
        let new = NetworkInfo.tailscaleIPv4().map { "http://\($0):\(port)" } ?? ""
        if new != tailscaleURL { tailscaleURL = new }
    }

    // MARK: - 손쉬운 사용(Accessibility) 권한

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(httpURL, forType: .string)
    }

    func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - 진단 로깅 (/tmp/macpilot-cmd.log)

    private let logURL = URL(fileURLWithPath: "/tmp/macpilot-cmd.log")

    private func resetLog() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }

    /// move/scroll(연속 명령)을 뺀 개별 명령만 파일에 기록 → 디버깅용
    private func logCommand(_ command: InboundCommand) {
        guard command.t != "move", command.t != "scroll" else { return }
        let line = "[\(command.t)] dir=\(command.dir ?? "-") btn=\(command.button ?? "-") key=\(command.keyCode.map(String.init) ?? "-")\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
