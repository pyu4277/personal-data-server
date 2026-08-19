# 개인 데이터 서버 — 구축 현황 및 인수인계

작성: 2026-08-19 · 코디네이터: Claude (Opus)
대상 호스트: `HJYUHomeMain` (Windows 11 Pro 23H2, Entra ID 조인)

> 이 문서는 다음 작업 세션의 출발점이다. 자격증명은 여기 적지 않는다 —
> `C:\ProgramData\HomeDataServer\credentials.txt` 참조.

---

## 1. 목표와 최종 결론

**목표**: 공유기 기반 홈네트워크에서 여러 PC가 데이터를 공유하는 서버를 만들고,
내부 유선망뿐 아니라 **외부에서도 접속** 가능하게 한다. Google Drive 의존을 끊는다.

**핵심 제약 (실측)**: KT 회선이 **CGNAT** 뒤에 있어 포트포워딩이 원천 불가.
→ 아웃바운드 오버레이(Tailscale)만이 유일한 외부 접속 경로.

---

## 2. 확정된 환경 (재조사 불필요)

### 호스트
| 항목 | 값 |
|---|---|
| CPU / RAM | Intel i9-12900K (16C/24T) / 31.75 GB |
| 저장장치 | KLEVV CRAS C920 M.2 NVMe 1TB (D:, J:) + Samsung 850 PRO ×2 (C:, E:) |
| 조인 상태 | **Entra ID (AzureAD)**, 도메인 조인 아님 |
| 로컬 계정 | 원래 전부 비활성 → 이번에 `shareuser` 신규 생성 |
| 전원 | AC에서 절전·최대절전 **비활성화 완료** (상시 가동) |

### 네트워크
| 항목 | 값 |
|---|---|
| 유선 LAN | `192.168.0.20` (Intel I225-V) — 주 경로 |
| 공유기 | **ipTIME AX6000M**, `192.168.0.1`, 관리도구 15.30.0, HTTP 전용(443 없음) |
| 공유기 WAN IP | **`10.123.216.73`** ← 사설 (CGNAT 증거) |
| 공인 IP | `220.67.182.216` (KT, AS4766) |
| IPv6 | **미제공** (CGNAT 우회로 없음) |
| UPnP | 동작함 (MiniUPnPd/1.6) — Tailscale이 이미 활용 중 |

### LAN 기기
```
.1   ipTIME 공유기          .12  Canon MF540 복합기
.11  PYU-Book6 (노트북)      .14  Intel NIC PC (침묵)
.9 / .15 / .17  스마트폰 (MAC 랜덤화)
NAS 없음. LAN에서 445 열린 호스트 0개였음.
```

### Tailscale (tailnet `tail80e577.ts.net`, 계정 pyu4277@gmail.com, **Free 플랜**)
```
100.95.190.99    hjyuhomemain    windows  ← 서버 + 서브넷 라우터
100.65.157.9     pyu-book6       windows
100.73.178.60    pyu-sjc-main    windows  ← ⚠ 키 만료 임박
100.116.142.126  s23-ultra       android
100.73.238.109   tab-s9-ultra    android
100.64.142.16    z-fold8-ultra   android
```
MagicDNS 활성 · HTTPS 인증서 **활성화 완료** · netcheck: UDP ok, cone NAT, DERP Tokyo 33ms

---

## 3. 구축한 것

### 데이터 루트
**`D:\` 드라이브 전체** (391.9 GB 여유). 포맷하지 않았고 `AndroidSDK`는 그대로 둠.
> `J:\`는 **Google Drive 미러 루트**라 서버 루트로 쓰면 안 됨 (동기화 경합·용량 소모).

### 서버 — SFTPGo v2.7.3 (오픈소스 AGPL-3.0, 무료)
```
Windows 서비스 "SFTPGo", 자동 시작(delayed-auto), 실패 시 자동 재시작
실행 계정: LocalSystem  (가상 서비스 계정은 오류 1057로 실패 → 벤더 기본값 사용)

127.0.0.1:8080   WebClient  (web_admin=false, rest_api=false)  ← 외부 노출 대상
127.0.0.1:8081   WebAdmin   (루프백 전용, 절대 프록시 안 함)
127.0.0.1:8090   WebDAV
SFTP/FTP         비활성 (port 0)
사용자 "pyu" home_dir=D:\ 권한 *
```
**루프백 바인딩이 설계의 핵심**: `Tailscale-In` 방화벽 규칙이 `100.95.190.99`에 대해
전 포트 allow이므로, `0.0.0.0`에 바인딩하면 Serve를 우회해 모든 피어에 직노출됨.

### 접속 경로 (Tailscale Serve, 전부 tailnet 한정)
```
https://hjyuhomemain.tail80e577.ts.net/         → SFTPGo 웹 UI    (Let's Encrypt)
https://hjyuhomemain.tail80e577.ts.net:8443/    → 공유기 관리 페이지 HTTPS 우회
https://hjyuhomemain.tail80e577.ts.net:10000/   → WebDAV
http://hjyuhomemain/                            → 웹 UI (짧은 이름용, 평문)
```
인증서: `CN=hjyuhomemain.tail80e577.ts.net`, Let's Encrypt, ~2026-11-16, 자동 갱신

### SMB (LAN 고속 경로)
```
\\HJYUHomeMain\Data  →  D:\     암호화 강제, SMB1 차단, 서명 필수
계정: shareuser (비관리자 로컬 계정)
방화벽: TCP 445를 192.168.0.0/24 → 192.168.0.20 에서만 허용. 인터넷 노출 0
```
Entra 조인 + 로컬계정 부재로 인한 SMB 인증 불가 문제를 `shareuser`로 해결.

### 서브넷 라우터
```
AdvertiseRoutes : 192.168.0.0/24
PrimaryRoutes   : 192.168.0.0/24   (관리 콘솔 승인 완료)
IP 포워딩       : 이더넷·Tailscale 모두 Enabled
```
→ 밖에서도 집안 기기 전체(공유기·Canon 복합기 등)에 직접 접근 가능.

---

## 4. 검증 완료 항목

| 검증 | 결과 |
|---|---|
| SFTPGo 웹 (로컬 8080/8081) | HTTP 200 |
| WebDAV (8090) | HTTP 401 (인증 요구 = 정상) |
| Tailscale MagicDNS 접속 | HTTP 200 |
| HTTPS 3경로 (인증서 검증 켜고) | 443 / 8443 / 10000 전부 통과 |
| SMB over tailnet | Z: 매핑 → 조회·쓰기·읽기·삭제 전부 성공 |
| 서브넷 경로 | `PrimaryRoutes` 반영, 공유기·복합기 포트 80 도달 |

---

## 5. 폐기한 선택지 (재검토 불필요)

| 후보 | 폐기 사유 |
|---|---|
| 공유기 포트포워딩 + DDNS | **CGNAT.** 공유기 WAN이 사설 IP. 인바운드가 KT에서 소멸 |
| ipTIME VPN 서버 (WireGuard/PPTP/L2TP) | 모델은 지원하나 인바운드 필요 → CGNAT에 막힘 |
| ipTIME ipDISK / DDNS | 아웃바운드 릴레이 없음. DDNS는 도달 불가 주소를 가리킴 |
| ipTIME NAS (USB) | 공유기 SoC 성능·제3자 경로 의존. NVMe 서버 대비 명백한 하향 |
| FileBrowser | **2026-09-01 저장소 아카이브**, 이후 보안패치 없음 |
| Nextcloud/Seafile (Docker) | Docker·WSL·Hyper-V 전부 미설치 상태. 과잉 |
| NordVPN Meshnet | 상용 VPN은 목적이 다름. Serve/인증서/MagicDNS 등가물 없음. 2025년 종료 발표 후 번복 이력 |
| Tailscale Funnel | 기술적으로 가능하나 공개 노출. 현재 요구사항 아님 |

---

## 6. 남은 작업

### 우선순위 A
1. ~~**`hjyuhomemain` 키 만료 해제**~~ — **완료 (2026-08-19)**. `Expiry disabled` 확인
2. ~~**`pyu-sjc-main` 키 만료 해제**~~ — **완료 (2026-08-19)**. 만료 17시간 전이었음
   > 교훈: Tailscale 키는 **재연결로 갱신되지 않는다.** 기기에서 `tailscale login`으로
   > 재인증하거나 콘솔에서 만료를 해제해야 한다. 사람이 쓰는 기기 4대는 보안상
   > 만료를 그대로 두었다 (PYU-Book6, S23, Z Fold8, tab-s9).
3. 피어 기기에서 **`Use Tailscale subnets`** 켜기 (Windows 트레이 / Android 앱) — **미완**

### 우선순위 B — 실사용 검증
4. ~~`pyu-book6` 접속 검증~~ — **완료.** `U:` 매핑, 읽기·쓰기·삭제 검증
5. ~~`pyu-sjc-main` 접속~~ — **완료 (사용자가 직접 연결).** 2026-08-19 23:06 인증,
   SMB 세션 2개 유지 확인
6. 안드로이드 브라우저에서 HTTPS 접속 확인 — **미검증**
7. Windows 피어에서 WebDAV 드라이브 문자 매핑 (`:10000`) — **미검증**

> **2026-08-20 실측 — 서버는 이미 업무 인프라다.**
> `Get-SmbSession` 조회 결과 동시 접속 3, 그중 한 세션이 **파일 234개를 열어둔 채
> 3시간 17분째** 작업 중이었다. `pyu-book6` 누적 수신 183 GB.
>
> 이 확인 과정에서 판단 오류가 하나 드러났다 — 앞서 `pyu-sjc-main` 을 "배포본 미실행"
> 으로 적었는데, 근거가 **Tailscale 트래픽량**(1.5 MB)이었다. SMB 세션은 붙어 있어도
> 파일을 읽기 전에는 트래픽이 keepalive 수준에 머물고, 같은 LAN 이면 Tailscale 을
> 우회할 수도 있다. **연결 여부는 `Get-SmbSession` 으로 직접 봐야 한다.**

### 우선순위 C — 운영 안정화
7. **백업 전략** — Google Drive를 떠났으므로 `D:\`에 백업이 없음. 현재 단일 장애점
8. Tailscale **ACL** 검토 — `Tailscale-In`이 전 포트 allow이므로 피어 1대 침해 시 전체 노출
9. 생성된 비밀번호를 본인이 원하는 값으로 변경 (SFTPGo 웹 UI에서 가능)
10. `ipTIME NAS Utility 2.04` 제거 여부 결정 (현재 무해하나 불필요)
11. **공유기 관리 비밀번호 변경 권장** (대화 기록에 노출됨)

### 보류 (사용자 결정으로 이번에 안 함)
- `J:\LocalDrive` 139 GB → 개인 서버 이관
- Tailscale Funnel (공개 노출)
- Syncthing (오프라인 복제본)

---

## 7. 오케스트레이션 기록

| 에이전트 | 역할 | 산출물 |
|---|---|---|
| Claude (코디네이터) | 계획·실행·검증·병합 | 이 문서, 설치 스크립트 |
| Claude 서브에이전트 ×4 | 공유기/WAN, 호스트 인벤토리, LAN 스캔, Tailscale 감사 | 세션 내 보고 |
| Codex (gpt-5.6-sol high) | 독립 아키텍처 제안 + 구현 스크립트 | `codex-architecture.md` |
| Antigravity (Gemini 3.1 Pro) | 위협모델·타당성 검토, ipTIME 조사 | `gemini-review.md`, `iptime-personal-server-research.md` |

교차검증이 실제로 값을 한 지점: Gemini가 "KT는 CGNAT를 쓰지 않는다"고 잘못 단정했으나
공유기 UPnP 실측(`10.123.216.73`)으로 반박되어 설계 방향이 바로잡힘.

---

## 8. 주요 파일 위치

```
C:\ProgramData\HomeDataServer\credentials.txt   자격증명 (SFTPGo admin/pyu, SMB shareuser)
C:\ProgramData\HomeDataServer\setup-*.log       설치 로그
C:\ProgramData\HomeDataServer\sftpgo.json.before-*  원본 설정 백업
C:\ProgramData\SFTPGo\sftpgo.json               현재 서버 설정
_orchestration\CONTEXT.md                       에이전트 공유 컨텍스트 (실측 사실 원본)
```
