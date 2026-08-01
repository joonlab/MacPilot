import CoreGraphics
import Foundation

/// CGEvent(Quartz Event Services)로 실제 마우스/키보드 입력을 합성한다.
///
/// ⚠️ **손쉬운 사용(Accessibility)** 권한이 없으면 이벤트가 시스템에 주입되지 않는다.
///    시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용 에서 이 앱을 허용해야 한다.
///
/// 모든 입력은 단일 직렬 큐에서 순서대로 주입되어, 드래그 상태(`isMouseDown`)가
/// 안전하게 유지되고 이벤트 순서가 보장된다.
enum EventInjector {

    private static let queue = DispatchQueue(label: "com.joonlab.macpilot.eventinjector")

    // 드래그 상태 (queue 위에서만 접근)
    private static var isMouseDown = false
    private static var downButton: CGMouseButton = .left

    static func perform(_ command: InboundCommand) {
        queue.async { apply(command) }
    }

    /// 연결이 끊겼을 때 눌린 버튼이 남지 않도록 해제
    static func releaseAll() {
        queue.async {
            if isMouseDown {
                let pos = currentLocation()
                let upType: CGEventType = downButton == .right ? .rightMouseUp : .leftMouseUp
                postMouse(upType, at: pos, button: downButton, clickState: 1)
                isMouseDown = false
            }
        }
    }

    // MARK: - 분기

    private static func apply(_ command: InboundCommand) {
        switch command.t {
        case "move":
            move(dx: command.dx ?? 0, dy: command.dy ?? 0)
        case "down":
            mouseDown(right: command.button == "right", clickState: command.count ?? 1)
        case "up":
            mouseUp()
        case "click":
            click(right: command.button == "right", count: command.count ?? 1)
        case "scroll":
            scroll(dx: command.dx ?? 0, dy: command.dy ?? 0)
        case "key":
            keyPress(keyCode: CGKeyCode(command.keyCode ?? 0), mods: command.mods ?? [])
        case "text":
            typeText(command.text ?? "")
        case "macro":
            runMacro(command.steps ?? [])
        case "launch":
            launch(command.target ?? "")
        case "gesture":
            gesture(command.dir ?? "")
        case "zoom":
            zoom(command.dir ?? "")
        case "volume":
            switch command.dir {
            case "up":   MediaKeys.press(MediaKeys.soundUp)
            case "down": MediaKeys.press(MediaKeys.soundDown)
            case "mute": MediaKeys.press(MediaKeys.mute)
            default: break
            }
        case "brightness":
            switch command.dir {
            case "up":   MediaKeys.press(MediaKeys.brightnessUp)
            case "down": MediaKeys.press(MediaKeys.brightnessDown)
            default: break
            }
        case "hello":
            break
        default:
            break
        }
    }

    // MARK: - 마우스

    private static func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// 이동. 버튼이 눌려 있으면 드래그(mouseDragged), 아니면 단순 이동(mouseMoved).
    private static func move(dx: Double, dy: Double) {
        let cur = currentLocation()   // 위치 조회는 한 번만 (이벤트당 syscall 절감)
        let target = clampToDisplays(CGPoint(x: cur.x + dx, y: cur.y + dy))
        if isMouseDown {
            let dragType: CGEventType = downButton == .right ? .rightMouseDragged : .leftMouseDragged
            postMouse(dragType, at: target, button: downButton, clickState: 1)
        } else {
            postMouse(.mouseMoved, at: target, button: .left, clickState: 1)
        }
    }

    private static func mouseDown(right: Bool, clickState: Int) {
        let pos = currentLocation()
        downButton = right ? .right : .left
        isMouseDown = true
        let downType: CGEventType = right ? .rightMouseDown : .leftMouseDown
        postMouse(downType, at: pos, button: downButton, clickState: max(1, clickState))
    }

    private static func mouseUp() {
        let pos = currentLocation()
        let upType: CGEventType = downButton == .right ? .rightMouseUp : .leftMouseUp
        postMouse(upType, at: pos, button: downButton, clickState: 1)
        isMouseDown = false
    }

    /// 클릭. count 가 2면 더블클릭, 3이면 트리플클릭(clickState 필드로 OS에 알림).
    private static func click(right: Bool, count: Int) {
        let pos = currentLocation()
        let state = max(1, count)
        let (downType, upType, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right)
                  : (.leftMouseDown, .leftMouseUp, .left)
        postMouse(downType, at: pos, button: button, clickState: state)
        postMouse(upType, at: pos, button: button, clickState: state)
    }

    private static func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.flags = []  // 잔류 모디파이어가 클릭을 Control+클릭(=우클릭)으로 만들지 않도록 명시적으로 비움
        if clickState > 1 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private static func scroll(dx: Double, dy: Double) {
        // 두 손가락 드래그 → 자연스러운 스크롤. 방향이 반대면 부호를 뒤집으세요.
        let vertical = Int32((-dy).rounded())
        let horizontal = Int32((-dx).rounded())
        CGEvent(scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: vertical,
                wheel2: horizontal,
                wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - 키보드

    /// 시스템 단축키(미션 컨트롤 등)도 인식되도록 **실제 모디파이어 키 down/up 이벤트**를
    /// 메인 키 앞뒤로 보낸다. 플래그만 세팅하면 WindowServer 핫키가 안 먹고,
    /// 모디파이어 상태가 잔류해 이후 클릭이 우클릭으로 처리되는 버그가 생긴다.
    private static func keyPress(keyCode: CGKeyCode, mods: [String]) {
        let source = CGEventSource(stateID: .combinedSessionState)

        // 보조키: (이름, 가상키코드, 플래그)
        let modifiers: [(name: String, code: CGKeyCode, flag: CGEventFlags)] = [
            ("command", 55, .maskCommand),
            ("shift",   56, .maskShift),
            ("option",  58, .maskAlternate),
            ("control", 59, .maskControl),
        ].filter { mods.contains($0.name) }

        var flags: CGEventFlags = []

        // 1) 보조키 누르기 (플래그 누적)
        for modifier in modifiers {
            flags.insert(modifier.flag)
            postKey(source: source, key: modifier.code, down: true, flags: flags)
        }
        // WindowServer가 모디파이어 '눌림'을 확실히 인식하도록 잠시 대기
        // (공간 전환/미션컨트롤 같은 심볼릭 핫키는 타이밍에 민감)
        if !modifiers.isEmpty { usleep(15000) }  // 15ms
        // 2) 메인 키 down/up
        postKey(source: source, key: keyCode, down: true, flags: flags)
        usleep(12000)                            // 12ms (키 눌림 유지)
        postKey(source: source, key: keyCode, down: false, flags: flags)
        usleep(5000)
        // 3) 보조키 떼기 (역순, 플래그 차감 → 상태를 깨끗하게 복원)
        for modifier in modifiers.reversed() {
            flags.remove(modifier.flag)
            postKey(source: source, key: modifier.code, down: false, flags: flags)
        }
    }

    private static func postKey(source: CGEventSource?, key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// 임의 문자열을 유니코드로 직접 입력 (한글·이모지 포함). 맥 IME를 거치지 않음.
    private static func typeText(_ string: String) {
        guard !string.isEmpty else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        var chars = Array(string.utf16)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.post(tap: .cghidEventTap)
        }
    }

    /// 매크로: 단계들을 순서대로 실행 (직렬 큐 위에서 동작하므로 delay 는 usleep).
    private static func runMacro(_ steps: [MacroStep]) {
        for step in steps.prefix(50) {   // 폭주 방지
            switch step.type {
            case "key":
                keyPress(keyCode: CGKeyCode(step.keyCode ?? 0), mods: step.mods ?? [])
            case "text":
                typeText(step.text ?? "")
            case "launch":
                launch(step.target ?? "")
            case "delay":
                let ms = min(max(step.ms ?? 0, 0), 5000)
                usleep(useconds_t(ms * 1000))
            default:
                break
            }
        }
    }

    // MARK: - 앱/시스템 실행

    /// 앱을 실행한다. `target`이 "/"로 시작하면 경로로, 아니면 앱 이름으로 연다.
    /// 미션 컨트롤처럼 합성 키로 안 먹는 시스템 기능을 앱 실행으로 대체.
    /// 앱·파일·링크를 연다.
    ///   "/..." (경로) 또는 "scheme://..." (웹 URL·커스텀 스킴) → `open <대상>`
    ///   그 외(앱 이름)                                        → `open -a <이름>`
    private static func launch(_ target: String) {
        guard !target.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if target.hasPrefix("/") || target.contains("://") {
            process.arguments = [target]
        } else {
            process.arguments = ["-a", target]
        }
        try? process.run()
    }

    /// 3손가락 스와이프 → 맥 트랙패드 기본 동작과 동일하게 매핑.
    /// 화살표 가상키코드: ← 123, → 124, ↓ 125, ↑ 126.
    /// (좌/우는 내추럴 스크롤 기준: 손가락을 왼쪽으로 밀면 오른쪽 데스크탑으로 이동)
    private static func gesture(_ dir: String) {
        switch dir {
        case "up":
            launch("/System/Applications/Mission Control.app")  // 미션 컨트롤
        case "down":
            keyPress(keyCode: 125, mods: ["control"])           // 앱 익스포제 (⌃↓)
        // ⚠️ 데스크탑 전환(⌃←/→)은 macOS 26이 합성 이벤트·CGS API 둘 다 막아 불가 확인됨.
        //    확실히 동작하는 ⌘←/→(뒤로/앞으로)로 매핑. (다른 동작 원하면 여기만 교체)
        case "left":
            keyPress(keyCode: 123, mods: ["command"])           // ⌘← 뒤로 (왼쪽으로 쓸기)
        case "right":
            keyPress(keyCode: 124, mods: ["command"])           // ⌘→ 앞으로 (오른쪽으로 쓸기)
        default:
            break
        }
    }

    /// 핀치 → 줌. ⌘= (확대) / ⌘- (축소) 키로 매핑.
    /// "=" 가상키코드 24, "-" 27. ⌘+/⌘- 를 지원하는 앱(Safari·미리보기·지도·Finder 등)에서 동작.
    private static func zoom(_ dir: String) {
        switch dir {
        case "in":
            keyPress(keyCode: 24, mods: ["command"])   // ⌘=
        case "out":
            keyPress(keyCode: 27, mods: ["command"])   // ⌘-
        default:
            break
        }
    }

    // MARK: - 디스플레이

    /// 모든 활성 디스플레이의 합집합(union) 경계로 제한 → 보조 모니터로도 커서 이동 가능.
    private static func clampToDisplays(_ point: CGPoint) -> CGPoint {
        let bounds = desktopBounds()
        let x = min(max(point.x, bounds.minX), bounds.maxX - 1)
        let y = min(max(point.y, bounds.minY), bounds.maxY - 1)
        return CGPoint(x: x, y: y)
    }

    private static func desktopBounds() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var rect = CGRect.null
        for display in displays {
            rect = rect.union(CGDisplayBounds(display))
        }
        return rect.isNull ? CGDisplayBounds(CGMainDisplayID()) : rect
    }
}
