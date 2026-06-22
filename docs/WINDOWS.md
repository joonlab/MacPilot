# MacPilot for Windows

휴대폰/태블릿 브라우저로 **Windows PC**를 무선 트랙패드·키보드·단축키 덱으로 조작합니다.
폰에 앱 설치가 필요 없고, macOS 버전과 **동일한 웹 클라이언트·WebSocket 프로토콜**을 그대로 사용합니다.

> Windows helper는 `WindowsHelper/`에 별도로 들어 있으며 기존 macOS 빌드에 영향을 주지 않습니다.

---

## 요구사항

- **Windows 10 / 11 (x64)**
- 빌드: **.NET 9 SDK** (`net9.0-windows` 타겟). 설치 확인: `dotnet --version` (예: `9.0.304`)
  - 이 저장소는 `C:\Program Files\dotnet`에 SDK가 있는 환경에서 빌드/검증되었습니다. `dotnet`이 PATH에 없으면
    `& "C:\Program Files\dotnet\dotnet.exe" ...` 처럼 전체 경로로 호출하세요.
- 폰/태블릿이 PC와 **같은 Wi‑Fi(사설망)** 에 있을 것

## 빌드

```powershell
dotnet restore .\WindowsHelper\MacPilot.Windows.sln
dotnet build   .\WindowsHelper\MacPilot.Windows.sln -c Release
dotnet test    .\WindowsHelper\MacPilot.Windows.sln -c Release
```

### 단일 실행 파일(self-contained) 배포 빌드 (선택)

```powershell
dotnet publish .\WindowsHelper\src\MacPilot.Windows\MacPilot.Windows.csproj `
  -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true
```

산출물(검증됨): `WindowsHelper\src\MacPilot.Windows\bin\Release\net9.0-windows\win-x64\publish\MacPilot.Windows.exe`
— **단일 파일 약 48MB**, .NET 런타임 미설치 PC에서도 그 파일 하나만 복사해 실행됩니다(웹 클라이언트도 내장).
함께 생성되는 `.pdb`(디버그 심볼)는 배포에 필수가 아닙니다.

> 참고: WinForms는 트리밍/Native AOT를 지원하지 않으므로 `PublishTrimmed`/AOT는 사용하지 마세요.
> 더 작은 용량이 필요하면 `--self-contained false`(framework-dependent, ~수MB)로 빌드하되 대상 PC에
> **.NET 9 Desktop 런타임** 설치가 필요합니다.

## 실행

```powershell
# 개발 중 직접 실행
dotnet run --project .\WindowsHelper\src\MacPilot.Windows

# 또는 빌드 산출물 실행
.\WindowsHelper\src\MacPilot.Windows\bin\x64\Release\net9.0-windows\MacPilot.Windows.exe
```

실행하면 트레이에 아이콘이 생깁니다. 트레이 메뉴에서 **접속 URL / IP 폴백 / 포트 / 연결된 기기 수 / 권한·제약 안내 /
종료** 를 확인할 수 있습니다.

### 옵션

| 옵션 | 설명 |
|---|---|
| `--port <N>` 또는 `-p <N>` | 포트 변경 (기본 8765). 환경변수 `MACPILOT_PORT` 도 가능 |
| `--localhost` | 루프백(127.0.0.1) 전용 바인드. 환경변수 `MACPILOT_LOCALHOST=1` 도 가능 |
| `--pin [NNNNNN]` | **PIN 페어링 켜기**(아래 "PIN 페어링" 참조). 값 생략 시 6자리 자동 생성, `--pin 135790`으로 고정 지정. 환경변수 `MACPILOT_PIN` 도 가능 |

## 방화벽 안내 (자동 추가하지 않음)

LAN의 폰에서 접속하려면 Windows Defender 방화벽이 인바운드 연결을 허용해야 합니다.

- **첫 실행 시 방화벽 허용 창이 뜨면 "개인 네트워크"를 체크해 허용**하세요(권장 방식, 관리자 권한 불필요할 수 있음).
- 수동으로 규칙을 추가하려면(관리자 PowerShell, **직접 판단 후 실행**):

  ```powershell
  # ⚠️ 관리자 권한 필요. 본인 환경을 확인하고 직접 실행하세요. 이 앱은 자동으로 추가하지 않습니다.
  New-NetFirewallRule -DisplayName "MacPilot (TCP 8765, Private)" `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8765 -Profile Private
  ```

  되돌리기: `Remove-NetFirewallRule -DisplayName "MacPilot (TCP 8765, Private)"`

> 초안 스크립트: `scripts/firewall-allow.ps1`, `scripts/firewall-remove.ps1` (실행 전 검토 필요)

## 휴대폰 접속 방법

1. 트레이 메뉴의 **접속 URL**(예: `http://192.168.0.42:8765`)을 폰 브라우저에 입력. (트레이에서 "접속 URL 복사" 가능)
2. 같은 Wi‑Fi(사설망)에 연결돼 있어야 합니다.
3. `<컴퓨터이름>.local` 주소는 환경에 따라 해석되지 않을 수 있어 **LAN IPv4 주소**를 기본으로 사용합니다.

> PC 본인에서 로컬 테스트 시에는 `http://127.0.0.1:8765` 를 사용하세요(서버는 IPv4로 바인드되며, 일부
> 환경에서 `localhost`는 IPv6 `::1`로 먼저 해석됩니다).

## 권한 / 제약 (숨기지 않고 명시)

- **관리자 권한 창에는 입력 불가**: 작업 관리자, UAC 프롬프트, 관리자로 실행된 앱, 잠금화면/보안 데스크톱에는
  표준 사용자 권한의 입력 주입이 전달되지 않습니다(Windows UIPI). 우회하지 않습니다.
- **밝기**: 노트북 내장 패널(WMI)에서만 동작할 수 있고, 외부 모니터는 대부분 미지원입니다(best-effort, 실패 시 무동작).
- **제스처/줌**: macOS와 1:1 대응이 없어 키 조합으로 매핑합니다(아래 표).
- **앱 목록**: 시작 메뉴 바로가기(.lnk) 기준. UWP/Store 앱은 현재 목록에 포함되지 않습니다.
- 진단 로그: `%LOCALAPPDATA%\MacPilot\helper.log`

### 제스처/줌 매핑 (Windows)

| 입력 | macOS | Windows |
|---|---|---|
| 3손가락 ↑ | 미션 컨트롤 | **Win+Tab** (작업 보기) |
| 3손가락 ↓ | 앱 익스포제 | **Win+D** (바탕화면 보기) |
| 3손가락 ← | ⌘← 뒤로 | **Ctrl+Win+←** (이전 가상 데스크톱) |
| 3손가락 → | ⌘→ 앞으로 | **Ctrl+Win+→** (다음 가상 데스크톱) |
| 핀치 확대/축소 | ⌘+ / ⌘- | **Ctrl+(+)/(−)** |

## 보안

- 기본값은 **LAN/localhost 전용**이며 **인증이 없습니다**(macOS 버전과 동일). 신뢰하는 홈 네트워크에서만 사용하세요.
- **포트 8765를 인터넷에 노출하지 마세요.**
- 루프백만 원하면 `--localhost` 로 실행하세요.
- 추가 보호가 필요하면 아래 **PIN 페어링**을 켜세요.

### PIN 페어링 (선택, 기본 OFF)

`--pin` 으로 켜면 폰이 PC 트레이에 표시된 **PIN을 한 번 입력**해야 트랙패드 UI와 입력(WebSocket)에 접근할 수 있습니다.

```powershell
# 6자리 PIN 자동 생성 (트레이 메뉴 "🔒 PIN: ..." 에 표시)
dotnet run --project .\WindowsHelper\src\MacPilot.Windows -- --pin
# 또는 고정 PIN
.\MacPilot.Windows.exe --pin 135790
```

- 폰이 접속하면 PIN 입력 페이지가 먼저 뜨고, 맞으면 인증 쿠키가 설정되어 이후 자동 접속됩니다.
- **기존 웹 클라이언트(app.js)는 수정하지 않습니다** — 인증은 전적으로 서버측에서 쿠키로 처리하며, 브라우저가
  WebSocket 핸드셰이크에 쿠키를 자동 첨부하는 방식입니다. macOS 버전과 프로토콜 호환성도 그대로 유지됩니다.
- 기본값은 OFF라 켜지 않으면 동작이 완전히 동일합니다(하위 호환).
- 한계: 인메모리 토큰(재시작 시 재페어링 필요), 평문 LAN 전송. 강한 보안이 필요하면 신뢰 네트워크 + `--localhost`
  병행을 권장합니다.

## 문제 해결

| 증상 | 점검 |
|---|---|
| 폰에서 접속 안 됨 | 같은 Wi‑Fi인지, 방화벽 허용했는지, 트레이의 LAN IPv4 URL을 썼는지 |
| 포트 충돌로 시작 실패 | 트레이 풍선/`helper.log` 확인 후 `--port` 로 변경 |
| 마우스/키가 안 먹는 특정 창 | 그 창이 관리자 권한인지(UIPI 제약) |
| 단축키가 엉뚱하게 동작 | 비‑US 키보드 레이아웃일 수 있음(문자 키코드는 US 기준; 일반 타이핑은 레이아웃 무관) |
| 밝기 안 됨 | 외부 모니터/데스크톱은 대부분 미지원(정상) |
| 스크롤 방향 반대 | 웹 설정의 스크롤 방향 반전 토글 사용, 또는 후속 과제로 서버측 조정 |

## 테스트 체크리스트

### 자동 테스트 (구현·검증 완료)

```powershell
dotnet test .\WindowsHelper\MacPilot.Windows.sln -c Release
```

- 명령 파싱(17종 + MacroStep), key 매핑(mac VK→Win VK, 51→Backspace 등), mouse 매핑(상대→절대 클램프, 스크롤 누적),
  protocol 호환(getDeck json 미인용 임베드), WebSocket 핸드셰이크(RFC6455 accept), 정적 서빙/경로 traversal 차단,
  그리고 실 루프백 서버 통합(HTTP 서빙·`/ws` 왕복·입력 라우팅·연결끊김 시 ReleaseAll).

### 수동 테스트 (실기기 + 폰 필요)

같은 Wi‑Fi의 폰 브라우저에서:

- [ ] 접속 (LAN IPv4 URL)
- [ ] 트랙패드 커서 이동
- [ ] 좌클릭 / 우클릭
- [ ] 드래그 선택(좌클릭 누른 채 트랙패드 드래그)
- [ ] 두 손가락 스크롤 (+ 방향/감도 확인)
- [ ] 키보드 텍스트 입력
- [ ] 한국어 입력
- [ ] 이모지 입력 😀
- [ ] 단축키 조합(복사 ⌘C→Ctrl+C 등)
- [ ] 덱 버튼 실행 / 매크로
- [ ] 앱·링크 실행
- [ ] 볼륨 업/다운/뮤트
- [ ] 재연결 후 마우스 버튼 stuck 없음(드래그 중 폰 Wi‑Fi 끊기 → 재접속)
- [ ] Windows Defender 방화벽 허용 안내 확인
- [ ] (있으면) 밝기 — 노트북 패널
- [ ] `--pin` 켜고: PIN 페이지 표시 → 올바른 PIN 입력 후 트랙패드 접근 / 틀린 PIN 거부
