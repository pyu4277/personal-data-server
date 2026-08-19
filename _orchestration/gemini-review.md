# ADVERSARIAL SECURITY & FEASIBILITY REVIEW

## 1. THREAT MODEL: Exposure Methods

Ranked from highest to lowest risk (Note: Public port-forwarding is off the table due to CGNAT):

1. **Tailscale Funnel (Public)**
   - **Risk Level:** MEDIUM.
   - **Attack Path:** Funnel routes public internet traffic directly through Tailscale's ingress infrastructure to a local port on this machine. Anyone on the internet with the `.ts.net` URL can reach the local application. If the web app has vulnerabilities, directory traversal, or weak auth, an attacker can exploit it to gain host access. Enabling Funnel requires activating HTTPS certificates in the Tailscale admin console and modifying the ACL to include the `funnel` nodeAttr.
2. **Cloudflare Tunnel (Public)**
   - **Risk Level:** MEDIUM.
   - **Attack Path:** Creates an outbound-only connection from the Windows host to Cloudflare's edge, exposing a local service to the internet. Like Funnel, any app-level vulnerability can be exploited if auth is bypassed. Additionally, Cloudflare acts as a Man-in-The-Middle. For a home Windows box, running `cloudflared` securely requires running it as a service, which is often misconfigured. Relying purely on Cloudflare Zero Trust (Access) can mitigate random scans, but misconfiguring the policy leaves the origin completely open. 
3. **Tailscale Serve (Tailnet-only)**
   - **Risk Level:** LOW (Recommended).
   - **Attack Path:** Traffic is end-to-end encrypted and restricted purely to authenticated devices on the Tailnet (`pyu4277@` account). An attacker would need to compromise a Tailscale-authenticated device or the user's Tailscale SSO account to even see the service.

## 2. KT FEASIBILITY VERDICT

*   **CGNAT Confirmation:** KT is definitively using Carrier-Grade NAT (CGNAT) on this residential line. The router's UPnP interface reports its WAN IP as `10.123.216.73`, an RFC1918 private address, while external services see `220.67.182.216`. There is a double translation happening (Tailscale -> ipTIME -> KT).
*   **IPv6 Status:** The line does not have IPv6 connectivity, so the standard IPv6 bypass for CGNAT is unavailable.
*   **Verdict on Port Forwarding:** Because of the CGNAT layer above the home router, **traditional port-forwarding and DDNS are entirely non-functional and impossible.** Exposing services directly to the public IP is not an option. All external access MUST rely on outbound-initiated overlays or tunnels (e.g., Tailscale Serve/Funnel, Cloudflare Tunnel).

## 3. THE ENTRA-ID SMB PROBLEM

*   **The Problem:** The host (`HJYUHomeMain`) is joined to Entra ID (Azure AD) and has no active local accounts. Entra ID joined devices do not have a traditional Active Directory Kerberos trust. 
*   **The Symptom:** When another PC (like `pyu-book6`) or an Android device attempts to access an SMB share on this host using `AzureAD\박용운`, it will fall back to NTLM authentication. This almost universally fails with an "Access Denied" or "Logon Failure" loop because cloud-native credentials cannot be validated locally without a hybrid trust or Entra Kerberos (which requires Azure Files).
*   **The Real Workaround:** Do not use SMB for this project. Since enabling a local account violates constraints, you must run a distinct server application (e.g., a WebDAV server, SFTP, or a lightweight web file browser) that maintains its own internal user database or uses token-based authentication independent of Windows SAM.

## 4. RED-TEAM CRITIQUE: Top 8 Failure Modes

1. **Attempting Public Port Forward on CGNAT**
   - *Symptom:* Connection timeouts from outside. The traffic hits the KT edge router and is dropped because there is no mapping to the 10.123.216.x internal address. 
2. **Entra ID SMB Auth Loop**
   - *Symptom:* "Incorrect username or password" prompt loops when Android or a peer PC tries to mount the share via Tailscale, despite correct credentials.
3. **Dual-Homed Asymmetric Routing (Wired .20 + Wi-Fi .18 on same subnet)**
   - *Symptom:* Intermittent packet loss, slow transfer speeds, or connection timeouts on the LAN. Windows sends requests out one interface and replies out the other, confusing stateful firewalls/switches.
4. **Host Sleep State**
   - *Symptom:* "Host Unreachable." Windows 11 defaults to sleeping after a period of inactivity. The server will silently go offline.
5. **Tailscale Key Expiry**
   - *Symptom:* The server node silently drops off the Tailnet after 180 days. Remote access ceases.
6. **Hidden UAC Prompts**
   - *Symptom:* An installation script or service launch hangs indefinitely. Because UAC is set to prompt and `AzureAD\박용운` requires elevation, remote deployment without a scheduled task or proper bypass will hang waiting for a user click on the physical monitor.
7. **Weak Web App Authentication via Tunnels**
   - *Symptom:* Ransomware deployment or data leak. If routing public traffic (Funnel/Cloudflare) to a simple python `http.server` or a web app with default credentials, attackers will quickly compromise it.
8. **Misconfiguring Tailscale Funnel**
   - *Symptom:* Funnel refuses to start or the URL returns an error. Funnel requires modifying the ACL in the Tailscale admin console to add the `funnel` nodeAttr and enabling HTTPS certificates. Simply running `tailscale funnel` is insufficient.

## 5. HARDENING CHECKLIST

Before exposing anything, the orchestrator MUST verify:

- [ ] **Disable Wi-Fi Interface:** Turn off the Wi-Fi adapter to kill the dual-homed `192.168.0.0/24` conflict. Rely solely on the wired connection.
- [ ] **Disable Sleep/Hibernation:** Run `powercfg /change standby-timeout-ac 0` to ensure the host remains awake as a server.
- [ ] **Disable Tailscale Key Expiry:** Log into the Tailscale admin console and set `hjyuhomemain` to "Disable Key Expiry".
- [ ] **Abandon SMB for Cross-Device Sharing:** Deploy an application-level server (e.g., FileBrowser, SFTPGo, or WebDAV) with its own credential store.

## 6. EXTERNAL ACCESS DECISION

*   **Recommendation:** **Tailscale Serve (Tailnet-only)**.
*   **Reasoning:** Since CGNAT makes port forwarding impossible, we must use an outbound overlay. Tailscale Serve restricts access solely to authenticated nodes within the user's tailnet (`pyu4277@gmail.com`). It adds zero public attack surface, leverages the already installed Tailscale infrastructure, and does not require complex third-party tunnel daemon setups (like Cloudflare Tunnel on Windows). It fundamentally eliminates the risk of botnet scanning and exploit attempts against the web app itself.
*   **What is lost:** You lose the ability to access the server seamlessly from arbitrary, untrusted devices (like a public library computer or a friend's phone) without first installing Tailscale and authenticating into your Tailnet. 

## 7. TAILSCALE INBOUND RULES AUDIT

*   **The Risk:** The Windows Firewall currently classifies the LAN adapters (Wi-Fi/Ethernet) as **Public** (blocking inbound by default) while the Tailscale adapter is **Private** with two explicitly injected rules that allow **ANY protocol, ANY port, and ANY program** inbound, scoped to `100.95.190.99`. This means the host implicitly trusts every node on the Tailnet with full access to all listening ports, completely bypassing Windows Firewall protections for Tailscale peers. If an attacker compromises a peer node (like an Android phone), they gain unfettered network access to every service bound to `0.0.0.0` or `100.95.190.99` on this host.
*   **Mitigation:** This broad trust is standard Tailscale behavior, but for a hardened server, it is too permissive. You should:
    1. Lock down the host's Windows Firewall rules by removing or disabling the Tailscale injected allow-all rule.
    2. Replace it with explicit allow rules ONLY for the specific ports needed by the file sharing app (e.g., port 8080).
    3. Alternatively, implement Tailscale ACLs in the admin console to restrict what ports other nodes can access on `hjyuhomemain`.
    4. For LAN access, the **Public** profile currently blocks everything. To allow local devices without Tailscale to connect, you must either change the Ethernet profile to **Private** or add an explicit inbound rule for the app's port on the Public profile. A simpler alternative is to ensure all peer devices access the server exclusively via Tailscale.
