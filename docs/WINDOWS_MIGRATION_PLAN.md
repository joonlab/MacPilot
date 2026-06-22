# MacPilot — Windows 포트 이행 계획 (WINDOWS_MIGRATION_PLAN)

> 기존 macOS 버전을 **그대로 유지**한 채, Windows 10/11에서 동일한 핵심 기능을 제공하는 별도 helper를
> 추가하는 이행 계획과 설계 근거를 정리한 문서입니다. macOS 소스(`MacHelper/Sources`, `project.yml`,
> `deploy.sh`)는 **수정하지 않았습니다.**

## 1. 현재 구조 (macOS)

```
MacHelper/Sources/        Swift 메뉴바 헬퍼
  HelperServer.swift        NWListener(8765) HTTP+WebSocket, 덱/앱 명령 분기
  HTTPWebSocketConnection   손수 짠 HTTP/1.1 + RFC6455 프레이밍 (외부 의존성 0)
  EventInjector.swift       CGEvent 마우스/키보드/스크롤/텍스트/매크로 (단일 직렬 큐)
  InboundCommand.swift      평평한 JSON 명령 모델 + MacroStep
  AppList / DeckStore       .app 스캔, 덱 영속화
  MediaKeys / NetworkInfo   미디어 키, .local/IP
  SpaceSwitcher.swift       비공개 CGS API — ⚠️ WebSocket 명령 경로에 연결 안 됨(미사용)
MacHelper/Web/            폰 브라우저 클라이언트 (vanilla HTML/CSS/JS, 프레임워크 0)
```

동작: 폰 브라우저 → `http://<mac>:8765` 접속 → Mac이 웹 UI 제공 → `ws://host/ws`로 평평한 JSON 명령 →
`EventInjector`가 CGEvent로 실제 입력 주입.

## 2. Windows 포트 전략

**핵심 판단:** Swift/macOS 코드를 Windows에서 컴파일하지 않고, **C#/.NET으로 별도 helper를 신규 구현**.
웹 클라이언트(`MacHelper/Web`)와 WebSocket 명령 프로토콜은 **변경 없이 재사용**.

- 신규 트리: `WindowsHelper/` (macOS 코드와 완전 분리)
- 언어/런타임: **C# / .NET 9 (`net9.0-windows`)**
- 아키텍처: **Option B** — `TcpListener` + `System.Net.WebSockets.WebSocket.CreateFromStream` + WinForms `NotifyIcon` 트레이
  - **런타임 NuGet 의존성 0** (BCL + Windows Desktop 프레임워크만)
  - 기존 Mac helper 자체가 손수 짠 `NWListener` + 수동 핸드셰이크 구조라 **거의 1:1 구조 이식**
  - `TcpListener`는 `0.0.0.0:8765`를 **일반 사용자 권한으로 바인드**(http.sys/URL ACL/관리자 불필요) — Mac과 동일
  - 손수 짠 것은 101 핸드셰이크뿐, 프레이밍/마스킹/ping-pong/close는 `WebSocket.CreateFromStream`이 처리
- 웹 자산: `MacHelper/Web/*`를 **링크 임베드**(복사 아님)해 단일 소스 유지

비교한 대안:
- **Option A** (ASP.NET Core Kestrel + WinForms): WS를 프레임워크가 처리하나 의존성 무게(~85–110MB)·배선 복잡.
- **Option C** (ASP.NET Core + WPF): QR/진단창 UX 최상이나 트레이 유틸엔 과중.
- 심사 점수(유지보수·구현난이도·의존성·패키징·트레이·테스트 합산): **B=26**, A=22, C=19 → B 채택.

### 디렉터리 구조 (실제 구현)

```
WindowsHelper/
  MacPilot.Windows.sln
  src/MacPilot.Windows/
    Program.cs                진입점(STA, DPI PerMonitorV2)
    app.manifest              asInvoker(무관리자) + OS 지원 선언
    Server/  HttpStaticServer · WebSocketHandshake · StaticAssets · ServerStatus
    Commands/ InboundCommand · MacroStep · Protocol · CommandDispatcher
    Input/   IInputInjector · Win32InputInjector · Win32Native · KeyMap · ModifierMap · MouseMath
    Apps/    AppListProvider · AppLauncher
    SystemControls/ MediaController · BrightnessController
    Net/ NetworkInfo   Storage/ DeckStore   Config/ AppSettings   Tray/ TrayApp   Diagnostics/ Log
  tests/MacPilot.Windows.Tests/   (76 tests: parsing · key/mouse map · protocol · handshake · static · WS 통합)
```

## 3. OS별 기능 대응표

| 기능 | macOS | Windows 구현 | 상태 |
|---|---|---|---|
| 커서 이동(상대) | CGEvent mouseMoved/Dragged | GetCursorPos+delta → 가상데스크톱 클램프 → 절대 SendInput | ✅ 지원 |
| 드래그(버튼 유지) | isMouseDown 직렬 큐 | held 상태 단일 워커 스레드 | ✅ 지원 |
| 좌/우/더블/트리플 클릭 | mouseEventClickState | count회 down/up 쌍 | ✅ 지원 |
| 스크롤 | scrollWheelEvent2(픽셀) | WHEEL/HWHEEL 120단위 누적 | ⚠️ 부분(방향 수동확인) |
| 키 입력/단축키 | CGKeyCode + 실제 모디파이어 | **mac VK→Win VK 표** + SendInput | ✅ 지원 |
| Unicode 텍스트(한/이모지) | keyboardSetUnicodeString | KEYEVENTF_UNICODE(UTF-16, 서러게이트) | ✅ 지원 |
| 매크로 | 직렬 실행(50/5000ms 캡) | 동일 | ✅ 지원 |
| 앱/링크 실행 | /usr/bin/open | Process.Start(UseShellExecute) | ✅ 지원 |
| 앱 목록 | .app 스캔 + 아이콘 | Start Menu .lnk 스캔 + 아이콘 PNG | ⚠️ 부분(UWP 제외) |
| 볼륨 | NSSystemDefined | VK_VOLUME_UP/DOWN/MUTE | ✅ 지원 |
| 밝기 | NSSystemDefined | WMI WmiSetBrightness(노트북 패널) | ❌ 부분/미지원 |
| 제스처(3손가락) | 미션컨트롤/⌘←→ | Win+Tab / Win+D / Ctrl+Win+←→ | ⚠️ 부분 |
| 줌(핀치) | ⌘+/⌘- | Ctrl + +/- | ⚠️ 부분 |
| 덱 동기화 | App Support/deck.json | %LOCALAPPDATA%\MacPilot\deck.json | ✅ 지원 |
| 트레이/상시 | MenuBarExtra + launchd | WinForms NotifyIcon (+ 시작프로그램 스크립트 초안) | ✅ 지원 / 등록은 수동 |
| 공간 전환 | 비공개 CGS | (명령 경로 밖, 스킵) | — 해당없음 |

## 4. 미지원 / 부분 지원 / 수동 확인 필요

- **밝기**: WMI는 내장 패널에서만 동작, 외부 모니터는 DDC/CI 필요(다수 미지원). 실패 시 무동작. → **부분/미지원**
- **제스처·줌**: Windows에 1:1 대응이 없어 키 조합으로 best-effort 매핑(사용자 선택: 가상 데스크톱+Task View). → **부분**
- **스크롤 방향/감도**: 픽셀→120단위 양자화로 방향·세기는 **실기기 수동 확인** 권장.
- **앱 목록**: Start Menu `.lnk` 기준. **UWP/Store 앱(shell:AppsFolder)** 은 미열거 → 후속 과제.
- **`<host>.local` (mDNS)**: Windows mDNS 미보장 → **LAN IPv4를 기본 URL**로 표시, `.local`은 best-effort.
- **elevated/보안 데스크톱**: 관리자 권한 창·UAC·잠금화면에는 입력 주입 불가(UIPI). 우회하지 않고 문서화. → **미지원(설계상)**

## 5. 보안 리스크

- 기본값은 **LAN/localhost 전용**, 인증 없음(기존 동작과 동일). 같은 Wi-Fi의 누구나 접속 가능.
- 포트 8765를 **인터넷에 노출 금지**(README/WINDOWS.md 명시).
- 첫 LAN 바인드 시 **Windows Defender 방화벽 허용 창** 발생 — 자동 추가하지 않고 사용자가 '개인 네트워크' 허용.
- `--localhost` 모드로 루프백 전용 바인드 가능.
- 방화벽 규칙/서비스/시작프로그램/관리자 권한은 **자동 실행하지 않음**(스크립트 초안만 제공).

## 6. 후속 과제 (Phase 2+)

- ✅ **(구현됨) PIN 페어링** — 선택적(`--pin`, 기본 OFF), 서버측 쿠키 기반이라 웹 클라이언트 무수정·하위 호환.
  남은 것: 토큰 영속화(재시작 후 유지), 디바이스 allowlist, 시도 횟수 제한 강화. 자세한 내용은 `docs/WINDOWS.md` "PIN 페어링".
- UWP/Store 앱 목록(shell:AppsFolder), 더 정교한 아이콘 추출
- 스크롤 방향/감도 설정 노출, 멀티모니터/DPI 보강
- IPv6 듀얼스택 바인드(현재 IPv4 `0.0.0.0`)
- 단일 파일 self-contained publish 최적화, 코드 서명/SmartScreen 대응
- Windows Service / 시작프로그램 자동 등록(승인 기반), MSIX 인스톨러
- GitHub Actions Windows 빌드/테스트

## 7. 제약 준수 확인

- macOS 코드(`MacHelper/Sources`, `project.yml`, `deploy.sh`) **무변경**.
- WebSocket 스키마 **breaking change 없음**(mac VK→Win VK는 서버 내부 해석, 와이어 포맷 불변) → adapter 불필요.
- `.env`/인증서/키/계정정보 **생성·출력 없음**.
- 방화벽/서비스/시작프로그램/관리자/포트 개방 **실제 실행 없음**(문서·스크립트 초안만).
- 빌드/단위·통합 테스트 **실제 실행 후** 본 문서 작성(아래 검증 결과 참조: `docs/WINDOWS.md`).
