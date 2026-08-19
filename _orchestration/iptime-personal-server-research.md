# ipTIME Personal Server Features & CGNAT Feasibility Research

**Target Environment:** ipTIME AX6000M (fw 15.30.0), KT Residential Internet (CGNAT, WAN IP: 10.123.216.73, Public IP: 220.67.182.216), No IPv6.

## 1. ipTIME Personal Server Features Enumeration
ipTIME 펌웨어는 개인 서버 운용 및 외부 접속을 위해 다양한 기능을 제공합니다.
*   **ipTIME DDNS (`xxx.iptime.org`):** 유동 IP 환경에서 기억하기 쉬운 도메인 네임을 공유기의 현재 공인 IP에 연결해 주는 네임 서비스입니다. 외부에서 도메인으로 접속하려면 **인바운드 라우팅(포트 개방)이 필수**입니다.
*   **ipDISK:** 공유기에 연결된 USB 저장장치를 외부에서 접근할 수 있게 해주는 파일 공유 서비스(FTP, WebDAV, SMB 결합) 및 전용 모바일/PC 앱입니다. 별도의 `xxx.ipdisk.co.kr` DDNS를 함께 제공합니다. 이 역시 공유기 IP로 직접 통신하므로 **인바운드 연결이 필수**입니다.
*   **ipTIME NAS Utility:** 로컬 네트워크(LAN) 상에 있는 ipTIME NAS나 공유기를 자동으로 검색하고 네트워크 드라이브를 연결해 주는 PC용 유틸리티입니다. 자체적인 외부 접속 기능은 없습니다.
*   **VPN 서버 (PPTP, L2TP/IPsec, OpenVPN, WireGuard):** 공유기 자체를 VPN 서버로 구동하여 외부 기기가 로컬 네트워크(LAN)에 안전하게 터널링할 수 있게 합니다. 클라이언트가 공유기를 향해 터널을 뚫어야 하므로 **인바운드 포트(예: WireGuard용 UDP 51820) 개방이 필수**입니다.
*   **원격 접속 / 원격 관리 (공유기 보안 기능):** 공유기의 HTTP 관리도구(192.168.0.1)를 외부 인터넷에서 특정 포트로 접속할 수 있게 열어줍니다. **인바운드 포트 개방 필수**.
*   **부가 서버 기능 (FTP, Samba, Torrent, DLNA, WebDAV):** 공유기의 USB 포트를 활용한 간이 NAS 기능입니다. Samba/DLNA는 로컬 전용이며, FTP와 WebDAV는 외부 접속을 지원하지만 **인바운드 포트 개방이 필수**입니다.

## 2. THE DECISIVE QUESTION: CGNAT 환경에서의 작동 여부
**결론부터 말씀드리면, 위에서 나열한 모든 기능은 CGNAT 환경에서 전혀 작동하지 않습니다.**

*   **인바운드 도달성(Inbound Reachability)의 부재:** CGNAT 환경에서는 KT의 상위 라우터가 공인 IP(220.67.182.216)를 수신한 뒤, 사설 IP(10.123.216.73)로 트래픽을 넘겨주기 위한 포트 매핑 테이블을 가지고 있지 않습니다. 외부에서 아무리 요청을 보내도 KT 망에서 폐기됩니다.
*   **ipDISK의 중계(Relay) 여부:** ipDISK는 Tailscale이나 QuickConnect(Synology)처럼 NAT를 뚫고 나가는 **아웃바운드 기반의 중계(Relay/Rendezvous) 서버를 제공하지 않습니다.** 단순히 DDNS 주소를 업데이트하고 FTP/WebDAV 포트 번호를 앱에 전달할 뿐입니다. 따라서 인터넷 커뮤니티(클리앙, 뽐뿌 등)의 수많은 실패 사례에서 보듯, CGNAT 하에서는 ipDISK 접속이 무조건 실패(타임아웃)합니다.

## 3. ipTIME DDNS의 IP 등록 방식과 실패 원인
*   ipTIME 공유기는 DDNS 갱신 시 **공유기가 할당받은 WAN IP(10.x.x.x)**와 **ipTIME 서버에서 관측한 IP(220.x.x.x)**를 모두 확인합니다.
*   사설 IP가 할당된 것을 감지하면 펌웨어에서 "사설 IP가 할당되어 DDNS 등록이 제한됩니다"라는 경고와 함께 등록을 거부하거나, 강제로 등록하더라도 실제 접속은 불가능합니다.
*   일부 설정으로 강제 등록하여 220.67.182.216이 등록된다 하더라도, 2번에서 설명한 바와 같이 해당 공인 IP로 들어오는 트래픽이 공유기까지 도달하지 못하므로 아무 의미가 없습니다.

## 4. AX6000M VPN 서버와 CGNAT
*   AX6000M은 최고급형 칩셋을 탑재하여 최신 WireGuard 서버를 포함한 4종의 VPN 서버 기능을 모두 완벽하게 지원합니다.
*   그러나 **CGNAT 환경에서는 절대 작동하지 않습니다.** 외부의 스마트폰이 VPN 서버에 연결하기 위해 `220.67.182.216:51820`으로 UDP 패킷을 쏘면, KT 라우터 선에서 드랍되어 공유기까지 도달하지 못합니다. 

## 5. ipTIME에 터널링(아웃바운드 릴레이) 기능이 있는가?
*   **없습니다.** ipTIME 펌웨어에는 Tailscale, ZeroTier, 또는 Cloudflare Tunnel과 같이 공유기 내부에서 외부 랑데부 서버로 **먼저(Outbound)** 연결을 맺어 터널을 뚫고 대기하는 기능(역방향 프록시/릴레이 서비스)이 존재하지 않습니다.
*   단순히 VPN '클라이언트' 기능(OpenVPN/WireGuard Client)은 있으나, 이를 이용해 외부 접속을 하려면 사용자가 직접 공인 IP를 가진 외부 VPS 서버를 임대하여 구축해야 하므로 턴키(Turnkey) 방식의 솔루션이 아닙니다. SFTPGo 같은 자체 서비스 앞단에 HTTPS 인증서를 발급해 씌워주는 역방향 터널 기능은 전무합니다.

## 6. VERDICT: Evidence-based Conclusion
**현재 환경에서 ipTIME의 외부 접속 기능은 완전히 무용지물이며, 기존에 구축된 Tailscale Serve + SFTPGo 조합을 대체하거나 보완할 수 있는 기능은 단 하나도 없습니다.**

*   **비교 (ipTIME vs Tailscale Serve):** ipTIME의 모든 서비스는 '공인 IP 기반 인바운드 개방'이라는 구시대적 네트워크 환경을 전제로 설계되었습니다. 반면, 현재 구축된 Tailscale Serve는 아웃바운드 NAT Traversal과 DERP 릴레이 서버를 통해 CGNAT를 완벽하게 우회하며, 유효한 Let's Encrypt HTTPS 인증서까지 제공합니다.
*   **결정:** ipTIME의 DDNS, ipDISK, VPN 서버 기능에 시간을 낭비할 필요가 없습니다. 현재 구축된 Tailscale Serve 기반의 접속 방식이 CGNAT 환경에서 외부 접속을 달성할 수 있는 **유일하고 완벽하게 우월한 해답**입니다. ipTIME 라우터는 단순히 내부 기기간 스위칭 및 인터넷 아웃바운드 게이트웨이 용도로만 취급해야 합니다.
