import CryptoKit
import Foundation
import Network

/// 번들 정적 자산을 시작 시 1회만 메모리에 적재 → 요청마다 디스크 I/O 없음.
/// (현장에서 여러 기기가 동시에 페이지를 받아도 즉시 응답)
/// 개발 오버라이드: `~/Library/Application Support/MacPilot/web/` 에 같은 이름의 파일이 있으면
/// 번들 캐시 대신 그 파일을 서빙한다 → 웹(HTML/JS/CSS)만 고칠 땐 재빌드 없이 반영.
/// (ad-hoc 서명 사용자는 재빌드 = 손쉬운 사용 권한 리셋이라 특히 유용)
/// 동기화 예: rsync -a --delete MacHelper/Web/ ~/Library/"Application Support"/MacPilot/web/
private enum AssetCache {
    struct Item { let file: String; let data: Data; let mime: String }

    static let overrideDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MacPilot/web", isDirectory: true)

    static let table: [String: Item] = {
        func load(_ file: String, _ mime: String) -> Item? {
            guard let dot = file.lastIndex(of: ".") else { return nil }
            let stem = String(file[..<dot])
            let ext = String(file[file.index(after: dot)...])
            guard let url = Bundle.main.url(forResource: stem, withExtension: ext),
                  let data = try? Data(contentsOf: url) else { return nil }
            return Item(file: file, data: data, mime: mime)
        }
        var t: [String: Item] = [:]
        if let a = load("index.html", "text/html; charset=utf-8") { t["/"] = a; t["/index.html"] = a }
        if let a = load("app.js", "application/javascript; charset=utf-8") { t["/app.js"] = a }
        if let a = load("style.css", "text/css; charset=utf-8") { t["/style.css"] = a }
        if let a = load("logo.png", "image/png") {
            for p in ["/logo.png", "/favicon.ico", "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"] { t[p] = a }
        }
        if let a = load("logo-mark.png", "image/png") { t["/logo-mark.png"] = a }
        if let a = load("logo-mark-dark.png", "image/png") { t["/logo-mark-dark.png"] = a }
        return t
    }()

    /// 경로에 대한 응답. 오버라이드 파일이 있으면 그걸 우선(개발용), 없으면 메모리 캐시.
    static func item(for cleanPath: String) -> Item? {
        guard let base = table[cleanPath] else { return nil }
        if let data = try? Data(contentsOf: overrideDir.appendingPathComponent(base.file)) {
            return Item(file: base.file, data: data, mime: base.mime)
        }
        return base
    }
}

/// 단일 TCP 연결을 받아 (1) 정적 파일 HTTP 응답 또는 (2) WebSocket 업그레이드를
/// 처리하는 미니 서버 커넥션. 외부 의존성 없이 직접 프레이밍을 구현한다.
///
/// 흐름: HTTP 헤더 수신 → `/` 등 GET 이면 정적 파일 응답 후 종료,
///       `Upgrade: websocket` 이면 101 핸드셰이크 후 텍스트 프레임을 명령으로 디코드.
final class HTTPWebSocketConnection {
    private let connection: NWConnection
    private let pairing: Pairing?
    private var buffer = [UInt8]()
    private var didUpgrade = false
    private var closing = false
    private var idleWork: DispatchWorkItem?   // 유효 요청 없이 매달린 연결 정리용

    var onCommand: ((InboundCommand) -> Void)?
    var onUpgrade: (() -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection, pairing: Pairing? = nil) {
        self.connection = connection
        self.pairing = pairing
    }

    /// 외부(서버)에서 강제 종료. 페어링을 켤 때 기존 미인증 연결을 끊는 데 사용.
    func forceClose() { closeNow() }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.onClose?()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        // 15초 안에 정상 요청(정적 서빙 or WS 업그레이드)이 없으면 연결을 끊는다.
        // → 포트 스캐너/half-open 연결이 쌓여 FD를 잠그는 것을 방지.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.didUpgrade, !self.closing else { return }
            self.closeNow()
        }
        idleWork = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: work)
        receiveLoop()
    }

    // MARK: - 수신 루프

    private func receiveLoop() {
        if closing { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(contentsOf: data)
                self.process()
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receiveLoop()
        }
    }

    private func process() {
        if didUpgrade {
            parseFrames()
        } else if let headerEnd = indexOfCRLFCRLF(buffer) {
            let headerBytes = Array(buffer[0..<headerEnd])
            buffer.removeFirst(headerEnd + 4)
            if let request = String(bytes: headerBytes, encoding: .utf8) {
                handleRequest(request)
            } else {
                closeNow()
            }
        }
    }

    // MARK: - HTTP

    private func handleRequest(_ request: String) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { closeNow(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { closeNow(); return }
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let isUpgrade = headers["upgrade"]?.lowercased().contains("websocket") == true

        // 페어링 게이트(활성 시): 미인증이면 PIN 페이지, WS 는 거절. 비활성이면 그대로 통과.
        if let pairing, pairing.enabled {
            let clean = path.split(separator: "?").first.map(String.init) ?? path
            if clean == "/pair" {
                handlePair(path: path); return
            }
            let token = Pairing.readCookie(headers["cookie"], name: Pairing.cookieName)
            if !pairing.isAuthorized(cookieToken: token) {
                if isUpgrade { closeNow() } else { servePairPage(error: false) }
                return
            }
        }

        if isUpgrade, let key = headers["sec-websocket-key"] {
            performHandshake(key: key)
        } else {
            serveStatic(path: path)
        }
    }

    /// `GET /pair?pin=######` 처리: 맞으면 쿠키 발급 후 "/" 로 리다이렉트, 틀리면 에러 페이지.
    private func handlePair(path: String) {
        var pin: String?
        if let query = path.split(separator: "?").dropFirst().first {
            for field in query.split(separator: "&") {
                let kv = field.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "pin" {
                    pin = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                }
            }
        }
        if let pairing, pairing.verifyPin(pin) {
            let cookie = "\(Pairing.cookieName)=\(pairing.currentToken()); Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly"
            let head = "HTTP/1.1 302 Found\r\nLocation: /\r\nSet-Cookie: \(cookie)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendRaw(head)
        } else {
            servePairPage(error: true)
        }
    }

    private func servePairPage(error: Bool) {
        let body = Data(Pairing.pairPageHTML(error: error).utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        idleWork?.cancel()
        closing = true
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func sendRaw(_ string: String) {
        idleWork?.cancel()
        closing = true
        connection.send(content: Data(string.utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func performHandshake(key: String) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        let accept = Data(digest).base64EncodedString()
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
        didUpgrade = true
        idleWork?.cancel()   // 정상 WS 연결은 타임아웃 대상 아님(상시 유지)
        onUpgrade?()
        parseFrames() // 버퍼에 남은 프레임 즉시 처리
    }

    private func serveStatic(path: String) {
        let clean = path.split(separator: "?").first.map(String.init) ?? path
        idleWork?.cancel()
        guard let item = AssetCache.item(for: clean) else {
            sendSimple(status: "404 Not Found", body: "Not Found"); return
        }

        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: \(item.mime)\r\n"
            + "Content-Length: \(item.data.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(item.data)
        closing = true
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func sendSimple(status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        closing = true
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private func closeNow() {
        closing = true
        idleWork?.cancel()
        connection.cancel()
    }

    // MARK: - WebSocket 프레임

    private func parseFrames() {
        while let frame = nextFrame() {
            switch frame.opcode {
            case 0x1: // text
                if let command = try? JSONDecoder().decode(InboundCommand.self, from: frame.payload) {
                    onCommand?(command)
                }
            case 0x8: // close
                sendFrame(opcode: 0x8, payload: Data())
                closeNow()
                return
            case 0x9: // ping → pong
                sendFrame(opcode: 0xA, payload: frame.payload)
            default:
                break
            }
        }
    }

    /// 버퍼 맨 앞에서 완성된 프레임 하나를 떼어낸다. 미완성이면 nil.
    private func nextFrame() -> (opcode: UInt8, payload: Data)? {
        let b = buffer
        guard b.count >= 2 else { return nil }

        let opcode = b[0] & 0x0F
        let masked = (b[1] & 0x80) != 0
        var length = Int(b[1] & 0x7F)
        var index = 2

        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = (Int(b[2]) << 8) | Int(b[3])
            index = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            var value = 0
            for i in 2..<10 { value = (value << 8) | Int(b[i]) }
            length = value
            index = 10
        }

        var maskKey = [UInt8](repeating: 0, count: 4)
        if masked {
            guard b.count >= index + 4 else { return nil }
            for i in 0..<4 { maskKey[i] = b[index + i] }
            index += 4
        }

        guard b.count >= index + length else { return nil }
        var payload = Array(b[index..<index + length])
        if masked {
            for i in 0..<length { payload[i] ^= maskKey[i % 4] }
        }
        buffer.removeFirst(index + length)
        return (opcode, Data(payload))
    }

    /// 서버 → 클라이언트로 텍스트 메시지 전송 (덱 동기화용)
    func sendText(_ string: String) {
        sendFrame(opcode: 0x1, payload: Data(string.utf8))
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n < 65536 {
            frame.append(126)
            frame.append(UInt8((n >> 8) & 0xff))
            frame.append(UInt8(n & 0xff))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((n >> (8 * i)) & 0xff)) }
        }
        var data = Data(frame)
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - 유틸

    private func indexOfCRLFCRLF(_ b: [UInt8]) -> Int? {
        guard b.count >= 4 else { return nil }
        var i = 0
        while i <= b.count - 4 {
            if b[i] == 13, b[i + 1] == 10, b[i + 2] == 13, b[i + 3] == 10 { return i }
            i += 1
        }
        return nil
    }
}
