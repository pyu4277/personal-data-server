# Independent architecture and implementation proposal

Date: 2026-08-18  
Target: `HJYUHomeMain`, Windows 11 Pro, Entra ID joined  
Status: design only — none of the commands below have been run

## Decision in one paragraph

Use two deliberately separate access paths to the same physical directory, `D:\SharedData`. For Windows PCs on the home LAN, use an authenticated Windows SMB 3 share at `\\192.168.0.20\Data`; it gives Explorer integration, rename/locking semantics, and LAN throughput that browser tools do not. Give SMB one new, non-administrator local credential (`shareuser`) solely to avoid cross-machine Entra ID authentication problems, require SMB encryption/signing, disable SMB1/NetBIOS, and add a narrow TCP 445 rule from `192.168.0.0/24` to the wired address `192.168.0.20`. That explicit rule is mandatory because both LAN adapters are measured as Public-profile/default-block. For every remote use case and for Android, use the SFTPGo WebClient over private Tailscale Serve at `https://hjyuhomemain.tail80e577.ts.net/web/client`. SFTPGo listens only on loopback, has its own users/passwords/TOTP, and Tailscale supplies device admission and encryption. The owner must first enable **HTTPS Certificates** on the Tailscale DNS admin page; current `CertDomains` is empty, so HTTPS Serve does not work before that one non-UAC console action. There is no router port-forward and no public service.

This is intentionally not one protocol everywhere. SMB is the best Windows LAN filesystem, while an application-authenticated web client is the safer and more usable remote/mobile interface. Both paths operate on the same files; they are not two replicas and therefore cannot create sync conflicts.

## Concrete topology

```text
LAN Windows PC
  └─ SMB 3 encrypted → 192.168.0.20:445 → \\HJYUHomeMain\Data ─┐
                                                               ├─ D:\SharedData
remote PC / Android browser                                    │
  └─ Tailscale → HTTPS :443 (Serve) → 127.0.0.1:8080 ─┘
                                      SFTPGo WebClient

local administration only
  └─ http://127.0.0.1:8081/web/admin → SFTPGo WebAdmin
```

The SFTPGo client binding exposes neither WebAdmin nor the admin token endpoint. The WebAdmin binding is a separate loopback-only port and is never proxied by Serve. SFTP, FTP, and WebDAV listeners in SFTPGo are disabled because they add no required capability here.

## Storage placement: why `D:` and never `J:`

`J:` is not an ordinary data volume despite its drive letter. It is the active Google Drive for Desktop mirror root: `desktop.ini` points at `GoogleDriveFS.exe`, `.tmp.driveupload` contains actively staged files, the root contains Google document stubs, and the 380 MB mirror metadata database records `LocalDrive` as a mirrored name. Putting a multi-client server tree under `J:` would make Google Drive upload every shared write, consume cloud quota silently, and race its sync engine against SMB/SFTPGo rename, atomic-upload, and delete operations. The ReadOnly attribute measured on every folder beneath `J:\LocalDrive` is an additional warning not to repurpose that namespace. A `SharedData` folder anywhere under `J:` is therefore explicitly prohibited, as is a junction or symlink from the chosen root back into `J:`.

Use `D:\SharedData`. `D:` (`DataAndETC`) is NTFS, about 393.7 GB total with 391.9 GB free, is outside the Drive mirror, and currently contains only `AndroidSDK` and `OrcaWorkspaces`. It is Disk 2 Partition 1 on the same KLEVV CRAS C920 M.2 NVMe as `J:`, so this safety choice costs no storage-performance tier. It does mean `D:` and `J:` share a physical failure domain: Google Drive mirroring and same-disk placement are not backups, so `D:\SharedData` still needs a separate versioned/offline backup target.

## Measured platform baseline and its effect on the choice

- Docker is absent; WSL and VirtualMachinePlatform are disabled; there is no WSL distribution, Hyper-V, IIS, OpenSSH Server, or Python runtime. Deploying Nextcloud/Seafile would first create an entire virtualization/container stack, and native IIS WebDAV would first enable a new Windows web-server surface. The recommendation does neither.
- `winget` 1.29.280 directly offers `drakkan.SFTPGo` 2.7.3. It also offers Syncthing 2.1.3, Rclone 1.75.0, Caddy 2.11.4, and `cloudflared` 2026.8.2. FileBrowser is not in winget at all. This makes the native SFTPGo service the only selected component with the desired own-user-database/browser role and a verified unattended package path.
- Node.js 24.19.0, npm 11.17.0, Git 2.55.0.4, GitHub CLI 2.97.0, curl 8.13.0, and .NET 7 runtime are present but unnecessary. The implementation remains PowerShell 5.1 plus Windows cmdlets and does not invent a Node/Python service wrapper.
- The i9-12900K and 31.75 GB RAM provide ample capacity; avoiding Docker is about attack surface and operational complexity, not performance. AC standby is already `0` (Never); the setup command merely reasserts that invariant. Fast Startup is enabled, so validation uses **Restart**, which always performs a full boot path, rather than treating an ordinary hybrid Shutdown/Power On as a cold-start service test.

## Why this wins against the named alternatives

| Candidate | Fit on this exact host | Decision |
|---|---|---|
| Windows SMB share | Best LAN performance and native Explorer drive mapping. File locking is appropriate for a central shared directory. Entra-to-Entra workgroup authentication is fragile, so it needs a purpose-created local, non-admin share account. TCP 445 must never be Internet-facing. | **Pick as the LAN primary.** Add a narrow wired-LAN rule. Existing private Tailscale rules also make it an optional Windows-only remote path; never use router forwarding. |
| Syncthing | Version 2.1.3 is available through winget and it is excellent when every machine needs an offline replica. Here it would multiply storage, propagate deletes, introduce conflict files, and make “the server copy” less authoritative. Its web UI is administration, not an Android file portal. | Do not pick. Add later only for a specifically selected offline folder, never as the primary shared store. |
| FileBrowser | Its small binary and own user database would otherwise fit the portal role. It is absent from winget, and upstream announced that v2.63.23 is its last planned release and that the repository will be archived on 2026-09-01, after which there will be no security fixes. | Do not deploy. SFTPGo fills this role and remains maintained. |
| Nextcloud in Docker | Rich collaboration, clients, sharing, and versioning, but Docker is absent and both WSL and VirtualMachinePlatform are disabled. It would add those platform features plus a database, PHP, background jobs, image upgrades, and filesystem mount/permission complexity. | Do not pick unless calendar/groupware/Office collaboration becomes a real requirement. |
| Seafile in Docker | Efficient sync and versioned libraries, but its server-managed block store is not the ordinary `D:\SharedData` tree that SMB should concurrently serve. It also adds Docker/database/backup complexity and makes recovery less transparent. | Do not pick for this shared-filesystem requirement. |
| MinIO | Strong S3-compatible object storage, not a multi-user desktop filesystem. Object semantics, buckets, access keys, and the S3 API are a poor fit for Explorer workflows and browser file management. | Do not pick unless an application specifically needs S3. |
| Native WebDAV through IIS | IIS is not installed. Enabling it would add Windows features, certificate lifecycle, request filtering, and an auth surface, while Windows WebDAV clients retain size/authentication/caching quirks. Windows or Basic authentication is a bad match for the Entra-joined/workgroup situation. | Do not pick. |
| SFTPGo native Windows service | Verified winget package 2.7.3, own embedded user database, WebClient, per-user permissions, TOTP, resumable transfers, native service lifecycle, and no Docker/Python/Node dependency. It can bind to loopback behind Serve. | **Pick for the remote/browser path.** Use HTTPS WebClient only; disable its other protocol listeners. |

The controlled exception to “prefer an application with its own user database” is SMB. Its new `shareuser` is local, non-admin, not an Entra identity, and is reachable only on the explicitly allowed LAN address and the existing private tailnet address—not through public Internet ingress. The primary remote path still uses SFTPGo’s database behind Tailscale.

Measured transport facts reinforce this split. SMB2 transport over the tailnet already reaches session setup and fails only at credentials; creating `shareuser` fixes that authentication layer, so Windows users may also use `\\100.95.190.99\Data` as a private secondary remote path. It is not the recommended cross-platform path because it exposes a Windows authentication service to every permitted tailnet peer and does nothing for Android browser use. The existing `Tailscale-In` rules allow every inbound protocol to local address `100.95.190.99`, so no new tailnet firewall rule is needed. Conversely, the SFTPGo backend must remain on `127.0.0.1`; otherwise those broad rules would make a directly bound application port immediately reachable and bypass the intended Serve endpoint.

Relevant upstream references: [SFTPGo Windows installation](https://docs.sftpgo.com/2.7/installation/), [SFTPGo Web interfaces](https://docs.sftpgo.com/2.7/web-interfaces/), [SFTPGo configuration](https://docs.sftpgo.com/2.7/config-file/), [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve), and [FileBrowser final-release notice](https://github.com/filebrowser/filebrowser/releases).

## External-access choice

### Pick: Tailscale Serve, not Funnel

The production mapping is:

```powershell
& 'C:\Program Files\Tailscale\tailscale.exe' serve --bg --yes --https=443 http://127.0.0.1:8080
```

That makes only the SFTPGo client portal available to authenticated devices in `tail80e577.ts.net`. Serve terminates HTTPS with a certificate for `hjyuhomemain.tail80e577.ts.net`, obeys tailnet access policy, survives reboot when configured with `--bg`, and needs neither a public DNS record nor a router rule. A remote PC and Android must have Tailscale connected; that is a feature, not a limitation, for a private family server.

Capabilities must not be conflated:

- **Works immediately in the measured state:** ordinary tailnet address connectivity, raw TCP Serve, and HTTP Serve such as `tailscale serve --bg --http=8088 http://127.0.0.1:8080`. MagicDNS already resolves. This temporary HTTP URL would be `http://hjyuhomemain:8088/web/client`; its packets are encrypted by Tailscale, but browsers do not treat the origin as HTTPS, so use it only as a short connectivity diagnostic and turn it off with `tailscale serve --http=8088 off`.
- **Requires one owner action first:** HTTPS Serve. In the Tailscale admin console, open DNS and enable **HTTPS Certificates**. No ACL `funnel` node attribute is needed for private Serve. After the control plane populates `CertDomains`, the production `--https=443` command above works.
- **Requires two owner actions and is not selected:** Funnel needs HTTPS Certificates **and** the `funnel` node attribute in the tailnet ACL policy. Current CapMap has no Funnel capability. Do not enable either Funnel exposure or its ACL attribute for this design.

Do not use Tailscale Funnel. Funnel would turn the same endpoint into a public Internet service. SFTPGo authentication would still exist, but bot traffic, password attacks, application vulnerabilities, and public-share mistakes would all become relevant. Funnel is justified only if unaffiliated users must reach the site without Tailscale; that is not the stated goal.

### Why direct KT ingress is impossible here

The ipTIME AX6000M reports WAN address `10.123.216.73` while Internet observers see `220.67.182.216`. That is measured KT carrier-grade NAT above the user-owned router. There is no delivered IPv6 address. Consequently, an ipTIME port-forward and DDNS record cannot accept an unsolicited Internet connection on this line, regardless of whether KT generally filters port 80/443. Only outbound-initiated overlays/tunnels work unless KT supplies a public/static IP plan.

| Public option | What it requires | Assessment |
|---|---|---|
| Router TCP 443 forward + DDNS + Caddy | The ipTIME could create its own NAT mapping, but KT’s upstream CGNAT has no matching mapping and drops the unsolicited connection. DDNS would point at a carrier-shared public address, not a controllable WAN address. | **Impossible on the present line.** Mentioned only to rule it out. It becomes technically possible only after KT assigns a true public/static IP; even then never forward 445/3389. |
| Cloudflare Tunnel | A domain in Cloudflare, `cloudflared` service, outbound tunnel, and preferably Cloudflare Access in front of SFTPGo. No inbound router rule and it works through address changes/CGNAT, but traffic and identity policy depend on another cloud control plane. | The viable public fallback on the present line, but unnecessary because all intended devices can join the existing tailnet. |
| Tailscale Funnel | Outbound-initiated, so it traverses CGNAT, but intentionally public. It is not currently enabled; HTTPS Certificates plus an ACL `funnel` node attribute are both required. | Technically available after two owner changes, still the wrong exposure model. |
| Tailscale Serve | Outbound-initiated and therefore CGNAT-safe. Private device identity plus SFTPGo user identity, existing MagicDNS, and already-installed software. HTTP/raw TCP work now; HTTPS needs the DNS-page certificate switch. | **Selected, with HTTPS Certificates enabled first.** |

Router requirements for the selected design are therefore minimal: using the router’s LAN-only plaintext HTTP UI from a trusted wired/LAN device, reserve `192.168.0.20` for the wired NIC MAC, and confirm there are **no** forwards for 445, 3389, 8080, 8081, or 443 to this PC. A forward cannot cross KT CGNAT and is not needed for Serve. Keep Wi-Fi connected only if it is actually needed; clients should use `192.168.0.20` for SMB so the dual-homed `.18`/`.20` host cannot resolve ambiguously.

## AhnLab V3 / host and network IPS

AhnLab V3 Internet Security 9.0 is the primary antivirus, and both `TNHipsNt` (host IPS) and `TNNipsNt` (network IPS) drivers are measured Running. These filters sit outside the simple Windows Firewall-rule model: V3 can quarantine or prevent `sftpgo.exe` from launching after winget installation, and its network IPS can reject a new Serve/SMB flow even when `Get-NetFirewallRule` says it is allowed. This does not justify disabling V3.

Use this fault-isolation order:

1. Confirm package/service integrity locally: `winget list --id drakkan.SFTPGo --exact`, `Get-Service sftpgo`, and `Get-Item 'C:\Program Files\SFTPGo\sftpgo.exe'`. If the package reports installed but the binary disappears or the service start returns access/quarantine errors, inspect V3’s detection/quarantine history.
2. Confirm backend binding independently of the network: `Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort 8080,8081` and `curl.exe -I http://127.0.0.1:8080/web/client`. If this fails, troubleshoot SFTPGo/V3 host IPS before Tailscale or Windows Firewall.
3. Confirm the proxy and overlay: `tailscale serve status`, then from a peer run `tailscale ping hjyuhomemain` and `Test-NetConnection 100.95.190.99 -Port 443`. If loopback works and ping works but TCP 443 does not, review V3 network-IPS events alongside Serve status.
4. If V3 identifies a false positive, verify the package ID/source, executable path, and file hash, update V3 signatures, then create the narrowest product-supported exception for the exact SFTPGo executable or flow. Never disable all real-time, HIPS, or NIPS protection and never exempt all of `D:` or all Tailscale traffic.

The setup script records driver state before installing and throws if the expected SFTPGo service/config/binary is absent afterward. End-to-end peer tests remain necessary because a Running listener proves only the host side, not passage through `TNNipsNt`.

## Implementation package

### Before running it

1. In the ipTIME AX6000M’s LAN-only HTTP admin UI, reserve `192.168.0.20` for the Intel I225-V wired adapter. Do not add any port-forward; it cannot traverse KT CGNAT.
2. As tailnet owner, open the Tailscale admin console’s DNS page and enable **HTTPS Certificates**. Wait until this host’s `CertDomains` is populated. This is a web control-plane action, not Windows elevation. Do not add a Funnel node attribute.
3. Confirm `D:` is the measured `DataAndETC` NTFS volume, is automatically unlocked after reboot if BitLocker is used, and still has adequate free space. It currently has about 391.9 GB free of 393.7 GB.
4. Save the script below as `Install-HomeDataServer.ps1` in any ordinary folder. Review the five constants at its top.
5. Run it from a normal PowerShell 5.1 window. It self-elevates once, causing exactly one UAC prompt. Do not launch additional admin windows.

### One-UAC elevated setup script

This script is rerunnable for objects it previously created, but refuses to take over an unrelated local account or an SMB share that points elsewhere. It preserves the first-run rollback baseline in `C:\ProgramData\HomeDataServer` and never puts a password there. Console and generated text are UTF-8 without a BOM. Certificate readiness is checked before the share account or server configuration is changed.

```powershell
param([switch]$Elevated)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

# ---- Review these constants before execution ----
$DataRoot = 'D:\SharedData'
$ShareName = 'Data'
$ShareUser = 'shareuser'
$WiredAddress = '192.168.0.20'
$LanCidr = '192.168.0.0/24'
# -----------------------------------------------

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        throw 'Save this as a .ps1 file before running it.'
    }
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Elevated'
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs -ArgumentList $argLine -Wait -PassThru
    exit $proc.ExitCode
}

if (-not $Elevated) {
    throw 'Elevation marker missing.'
}

try {
    $StateRoot = 'C:\ProgramData\HomeDataServer'
    $SftpRoot = 'C:\ProgramData\SFTPGo'
    $SftpConfig = Join-Path $SftpRoot 'sftpgo.json'
    $SftpExe = 'C:\Program Files\SFTPGo\sftpgo.exe'
    $TailscaleExe = 'C:\Program Files\Tailscale\tailscale.exe'
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $statePath = Join-Path $StateRoot 'state.json'
    $priorState = $null
    if (Test-Path -LiteralPath $statePath) {
        $priorState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    if ($null -ne $priorState -and (Test-Path -LiteralPath $priorState.PowerConfigSnapshot)) {
        $powerSnapshot = $priorState.PowerConfigSnapshot
    } else {
        $powerSnapshot = Join-Path $StateRoot "powercfg-before-$timestamp.txt"
        & powercfg.exe /query SCHEME_CURRENT | Out-File `
            -LiteralPath $powerSnapshot -Encoding utf8
    }

    if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $WiredAddress -ErrorAction SilentlyContinue)) {
        throw "The verified wired address $WiredAddress is not assigned. Stop and fix the wired/DHCP state."
    }
    if (-not (Test-Path -LiteralPath 'D:\')) {
        throw 'D: is not mounted.'
    }
    $dataVolume = Get-Volume -DriveLetter 'D'
    if ($dataVolume.FileSystem -ne 'NTFS') {
        throw "D: must be NTFS; detected '$($dataVolume.FileSystem)'."
    }
    if ($dataVolume.SizeRemaining -lt 20GB) {
        throw 'D: has less than 20 GB free; stop and review capacity.'
    }
    if (Test-Path -LiteralPath 'D:\.tmp.driveupload') {
        throw 'D: contains a Google Drive upload-staging marker. Do not create the server root here until the mount identity is reviewed.'
    }

    # Preserve the measured security-filter baseline; do not disable AhnLab V3.
    Get-CimInstance -ClassName Win32_SystemDriver |
        Where-Object { $_.Name -in @('TNHipsNt', 'TNNipsNt') } |
        Select-Object Name, State, Status, StartMode, PathName |
        Out-File -LiteralPath (Join-Path $StateRoot "ahnlab-drivers-$timestamp.txt") `
            -Encoding utf8

    # HTTPS Serve is the selected production endpoint. Check its control-plane prerequisite
    # before making local users, shares, firewall rules, or server configuration changes.
    if (-not (Test-Path -LiteralPath $TailscaleExe)) {
        throw 'The verified Tailscale executable is missing.'
    }
    $tailscaleStatusText = (& $TailscaleExe status --json | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to read Tailscale status JSON.' }
    $tailscaleStatus = $tailscaleStatusText | ConvertFrom-Json
    $certDomains = @()
    if ($null -ne $tailscaleStatus.CertDomains) {
        $certDomains += @($tailscaleStatus.CertDomains)
    }
    if ($null -ne $tailscaleStatus.Self -and $null -ne $tailscaleStatus.Self.CertDomains) {
        $certDomains += @($tailscaleStatus.Self.CertDomains)
    }
    if ($certDomains.Count -eq 0) {
        throw 'Tailscale HTTPS Certificates are not enabled. Enable them on the tailnet DNS admin page, wait for CertDomains, then rerun. Do not enable Funnel.'
    }

    New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null

    # Create one non-admin identity only for LAN SMB. A rerun recognizes its exact marker.
    $managedUserDescription = 'Non-administrator account for HomeData LAN SMB only'
    $existingLocalUser = Get-LocalUser -Name $ShareUser -ErrorAction SilentlyContinue
    $sharePassword = Read-Host `
        "Enter/set the strong password for $env:COMPUTERNAME\$ShareUser (store it in a password manager)" `
        -AsSecureString
    if ($null -eq $existingLocalUser) {
        New-LocalUser -Name $ShareUser -Password $sharePassword `
            -Description $managedUserDescription `
            -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
    } else {
        if ($existingLocalUser.Description -ne $managedUserDescription) {
            throw "Local user '$ShareUser' exists but is not marked as managed by this script."
        }
        Set-LocalUser -Name $ShareUser -Password $sharePassword `
            -Description $managedUserDescription -PasswordNeverExpires $true `
            -UserMayChangePassword $false
    }
    $shareIdentity = "$env:COMPUTERNAME\$ShareUser"
    $shareSid = (Get-LocalUser -Name $ShareUser).Sid.Value

    # NTFS: retain existing inheritance, add only the two writers required by this design.
    & icacls.exe $DataRoot '/grant' "*$shareSid`:(OI)(CI)(M)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to grant the SMB account NTFS access.' }

    # Stop legacy SMB/NetBIOS behavior and require modern authenticated SMB.
    Set-SmbServerConfiguration -EnableSMB1Protocol $false `
        -EnableSecuritySignature $true -RequireSecuritySignature $true -Confirm:$false
    Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' |
        ForEach-Object {
            Invoke-CimMethod -InputObject $_ -MethodName SetTcpipNetbios `
                -Arguments @{ TcpipNetbiosOptions = [uint32]2 } | Out-Null
        }

    $oldShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($null -ne $oldShare -and $oldShare.Path -ne $DataRoot) {
        throw "SMB share '$ShareName' already points to '$($oldShare.Path)'; it was not changed."
    }
    if ($null -eq $oldShare) {
        New-SmbShare -Name $ShareName -Path $DataRoot -CachingMode None `
            -EncryptData $true -ChangeAccess $shareIdentity | Out-Null
    } else {
        Set-SmbShare -Name $ShareName -CachingMode None -EncryptData $true -Force
        Grant-SmbShareAccess -Name $ShareName -AccountName $shareIdentity `
            -AccessRight Change -Force | Out-Null
    }

    # Both physical adapters are currently Public/default-block. Add one address-scoped rule
    # instead of changing either adapter to Private or enabling the broad built-in SMB group.
    # Disable any pre-existing exact TCP/445 inbound allow rules; remember their invariant names.
    $disabledRuleNames = New-Object System.Collections.Generic.List[string]
    if ($null -ne $priorState) {
        foreach ($priorRuleName in @($priorState.DisabledFirewallRuleNames)) {
            if (-not $disabledRuleNames.Contains([string]$priorRuleName)) {
                $disabledRuleNames.Add([string]$priorRuleName)
            }
        }
    }
    $allowRules = Get-NetFirewallRule -Direction Inbound -Enabled True -Action Allow
    foreach ($rule in $allowRules) {
        $portFilters = @($rule | Get-NetFirewallPortFilter)
        $has445 = $false
        foreach ($portFilter in $portFilters) {
            if ($portFilter.Protocol -eq 'TCP' -and $portFilter.LocalPort -eq '445') {
                $has445 = $true
            }
        }
        if ($has445 -and $rule.Name -ne 'HomeData-SMB-LAN') {
            Disable-NetFirewallRule -Name $rule.Name | Out-Null
            if (-not $disabledRuleNames.Contains($rule.Name)) {
                $disabledRuleNames.Add($rule.Name)
            }
        }
    }
    Remove-NetFirewallRule -Name 'HomeData-SMB-LAN' -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name 'HomeData-SMB-LAN' -DisplayName 'HomeData SMB from wired LAN only' `
        -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol TCP `
        -LocalAddress $WiredAddress -LocalPort 445 -RemoteAddress $LanCidr | Out-Null

    # Install SFTPGo silently. Its official installer registers the Windows service.
    if ($null -ne $priorState) {
        $sftpWasPresent = [bool]$priorState.SftpGoWasPresent
    } else {
        $sftpWasPresent = Test-Path -LiteralPath $SftpExe
    }
    & winget.exe install --id drakkan.SFTPGo --version v2.7.3 --exact `
        --source winget --silent --disable-interactivity `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path -LiteralPath $SftpConfig)) {
        throw "SFTPGo config was not created at $SftpConfig."
    }
    if (-not (Test-Path -LiteralPath $SftpExe)) {
        throw 'SFTPGo package completed but sftpgo.exe is absent. Inspect AhnLab V3 quarantine/history.'
    }
    if (-not (Get-Service -Name 'sftpgo' -ErrorAction SilentlyContinue)) {
        throw 'SFTPGo Windows service is absent. Inspect installer output and AhnLab V3 host-IPS history.'
    }
    Stop-Service -Name 'sftpgo' -Force -ErrorAction SilentlyContinue

    if ($null -ne $priorState -and (Test-Path -LiteralPath $priorState.SftpGoConfigBackup)) {
        $configBackup = $priorState.SftpGoConfigBackup
    } else {
        $configBackup = Join-Path $StateRoot "sftpgo.json.before-$timestamp"
        Copy-Item -LiteralPath $SftpConfig -Destination $configBackup -Force
    }
    $cfg = Get-Content -LiteralPath $SftpConfig -Raw | ConvertFrom-Json

    # Clone the stock HTTP binding into a client-only port and a local-admin-only port.
    $clientBinding = ($cfg.httpd.bindings[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $adminBinding = ($cfg.httpd.bindings[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $clientBinding.address = '127.0.0.1'
    $clientBinding.port = 8080
    $clientBinding.enable_web_admin = $false
    $clientBinding.enable_web_client = $true
    $clientBinding.enable_rest_api = $true
    $clientBinding.disabled_login_methods = 80 # disable admin token + admin API-key login
    $clientBinding.hide_login_url = 2
    $clientBinding.render_openapi = $false
    $clientBinding.proxy_allowed = @('127.0.0.1')
    $clientBinding.client_ip_proxy_header = 'X-Forwarded-For'
    $clientBinding.client_ip_header_depth = -1

    $adminBinding.address = '127.0.0.1'
    $adminBinding.port = 8081
    $adminBinding.enable_web_admin = $true
    $adminBinding.enable_web_client = $false
    $adminBinding.enable_rest_api = $true
    $adminBinding.disabled_login_methods = 0
    $adminBinding.hide_login_url = 1
    $adminBinding.render_openapi = $false
    $adminBinding.proxy_allowed = @()
    $adminBinding.client_ip_proxy_header = ''
    $cfg.httpd.bindings = @($clientBinding, $adminBinding)

    # Disable protocols that this architecture does not use.
    foreach ($binding in $cfg.sftpd.bindings) { $binding.port = 0 }
    foreach ($binding in $cfg.ftpd.bindings) { $binding.port = 0 }
    foreach ($binding in $cfg.webdavd.bindings) { $binding.port = 0 }

    # Atomic uploads, brute-force defense, strong stored passwords, and proxy-aware HTTPS headers.
    $cfg.common.upload_mode = 1
    $cfg.common.defender.enabled = $true
    $cfg.common.defender.driver = 'memory'
    $cfg.common.defender.threshold = 10
    $cfg.common.defender.observation_time = 30
    $cfg.data_provider.password_hashing.algo = 'argon2id'
    $cfg.data_provider.password_validation.admins.min_entropy = 50
    $cfg.data_provider.password_validation.users.min_entropy = 50
    $cfg.httpd.security.enabled = $true
    $cfg.httpd.security.allowed_hosts = @()
    $cfg.httpd.security.hosts_proxy_headers = @('X-Forwarded-Host')
    $cfg.httpd.security.https_proxy_headers = @(
        [pscustomobject]@{ key = 'X-Forwarded-Proto'; value = 'https' }
    )
    $cfg.httpd.security.sts_seconds = 31536000
    $cfg.httpd.security.content_type_nosniff = $true
    $cfg.httpd.security.referrer_policy = 'same-origin'
    $cfg.httpd.security.cache_control = 'private'

    # Persist a random signing key in an ACL-protected file instead of changing it every reboot.
    $signingFile = Join-Path $SftpRoot 'signing-passphrase.txt'
    if (-not (Test-Path -LiteralPath $signingFile)) {
        $random = New-Object byte[] 64
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($random)
        [IO.File]::WriteAllText($signingFile, [Convert]::ToBase64String($random), $Utf8NoBom)
    }
    $cfg.httpd.signing_passphrase = ''
    $cfg.httpd.signing_passphrase_file = $signingFile
    [IO.File]::WriteAllText(
        $SftpConfig,
        ($cfg | ConvertTo-Json -Depth 100),
        $Utf8NoBom
    )

    # Replace the installer's broad program firewall exception. No exception is needed for loopback.
    Get-NetFirewallRule -DisplayName 'SFTPGo Service' -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule

    # Run SFTPGo as its own virtual service account rather than LocalSystem.
    & sc.exe sidtype sftpgo unrestricted | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to enable the SFTPGo service SID.' }
    & sc.exe config sftpgo obj= 'NT SERVICE\sftpgo' password= '' start= delayed-auto | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set the SFTPGo virtual service account.' }
    $serviceSid = (New-Object Security.Principal.NTAccount('NT SERVICE', 'sftpgo')).Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
    & icacls.exe $SftpRoot '/inheritance:r' `
        '/grant:r' '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' `
        "*$serviceSid`:(OI)(CI)(M)" '/T' '/C' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to secure the SFTPGo data/config directory.' }
    & icacls.exe $DataRoot '/grant' "*$serviceSid`:(OI)(CI)(M)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to grant SFTPGo access to the data root.' }

    & sc.exe failure sftpgo reset= 86400 `
        actions= restart/5000/restart/15000/restart/60000 | Out-Null
    & sc.exe failureflag sftpgo 1 | Out-Null
    Start-Service -Name 'sftpgo'
    Set-Service -Name 'LanmanServer' -StartupType Automatic
    Set-Service -Name 'Tailscale' -StartupType Automatic

    # A server cannot serve while asleep. This changes AC sleep only, not display timeout.
    & powercfg.exe /change standby-timeout-ac 0
    if ($LASTEXITCODE -ne 0) { throw 'Failed to disable AC sleep.' }

    # Publish only the client binding, privately, and persist it across reboot.
    & $TailscaleExe serve --bg --yes --https=443 http://127.0.0.1:8080
    if ($LASTEXITCODE -ne 0) {
        throw 'Private HTTPS Serve failed. Inspect its output and tailnet certificate state; do not substitute Funnel or a router forward.'
    }

    $state = [pscustomobject]@{
        CreatedAt = (Get-Date).ToString('o')
        DataRoot = $DataRoot
        ShareName = $ShareName
        ShareUser = $ShareUser
        ShareUserCreated = $true
        SftpGoWasPresent = $sftpWasPresent
        SftpGoConfigBackup = $configBackup
        DisabledFirewallRuleNames = @($disabledRuleNames)
        PowerConfigSnapshot = $powerSnapshot
    }
    [IO.File]::WriteAllText(
        $statePath,
        ($state | ConvertTo-Json -Depth 10),
        $Utf8NoBom
    )

    # Fail closed if a listener unexpectedly escaped loopback.
    Start-Sleep -Seconds 2
    $badWebListeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.LocalPort -eq 8080 -or $_.LocalPort -eq 8081) -and
            $_.LocalAddress -ne '127.0.0.1'
        }
    if ($badWebListeners) {
        throw 'A SFTPGo web listener is not loopback-only. Stop the service and inspect sftpgo.json.'
    }
    if (-not (Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort 8080 `
        -ErrorAction SilentlyContinue)) {
        throw 'SFTPGo client listener did not start on 127.0.0.1:8080.'
    }

    Write-Host ''
    Write-Host 'OS-level setup completed.' -ForegroundColor Green
    Write-Host 'Next: create SFTPGo admin at http://127.0.0.1:8081/web/admin'
    Write-Host 'Then create per-device users whose Home Dir is D:\SharedData.'
    Write-Host 'Client URL: https://hjyuhomemain.tail80e577.ts.net/web/client'
    Write-Host 'LAN SMB: \\192.168.0.20\Data'
} catch {
    Write-Error $_
    Write-Host 'Setup stopped. Review C:\ProgramData\HomeDataServer and use the rollback section.'
    exit 1
}
```

### Application setup after the script (no UAC)

These are SFTPGo application actions, not Windows administrator actions, so they do not cause additional UAC prompts:

1. On `HJYUHomeMain`, browse to `http://127.0.0.1:8081/web/admin`. Create a unique admin name and a password-manager-generated password, then enroll TOTP. This page cannot be reached from another machine.
2. Create one SFTPGo user per device/person, for example `book6`, `sjc-main`, `s23-ultra`, and `tab-s9-ultra`. Give each a unique password and optional TOTP.
3. For each user, select Local filesystem, set **Home Dir** to exactly `D:\SharedData`, and grant only the needed root permissions. For ordinary trusted devices, allow list/download/upload/overwrite/rename/create-directory/delete. Leave symlink creation disabled. Distinct accounts give revocation and auditability while pointing to the same data.
4. Do not reuse the SMB `shareuser` password as an SFTPGo password. Do not create public share links unless there is a specific need and expiry/password are set.
5. Store SFTPGo’s database/config and `D:\SharedData` in the backup plan. RAID, sync, and Tailscale are not backups.

### LAN Windows client setup (non-admin)

Run this on each LAN PC in a normal Command Prompt. The `*` makes Windows prompt without exposing the password in shell history:

```bat
net use Z: /delete
net use Z: \\192.168.0.20\Data /user:HJYUHomeMain\shareuser * /persistent:yes
```

Use the IP deliberately. `\\HJYUHomeMain\Data` can resolve to `.18` or `.20` on this dual-homed same-subnet host, while the firewall intentionally accepts only traffic to `.20`.

## Verification checklist

Create a small UTF-8 test file named `server-e2e-<date>.txt`; do not use an important file for the first write/delete test.

### On `HJYUHomeMain`

- [ ] `Get-Volume -DriveLetter D` shows NTFS `DataAndETC` with expected capacity, and `Test-Path D:\.tmp.driveupload` is false. The share path is `D:\SharedData`; no server path, junction, or SFTPGo home points into `J:`.
- [ ] `Get-CimInstance Win32_SystemDriver | Where-Object { $_.Name -in @('TNHipsNt','TNNipsNt') }` shows both AhnLab drivers Running. The saved baseline under `C:\ProgramData\HomeDataServer` matches.
- [ ] `Get-Service sftpgo,Tailscale,LanmanServer` reports all three `Running`; SFTPGo and Tailscale start automatically.
- [ ] `Get-NetTCPConnection -State Listen -LocalPort 8080,8081` shows only `127.0.0.1`, never `0.0.0.0`, `::`, `192.168.0.20`, or a `100.x` address.
- [ ] `curl.exe -I http://127.0.0.1:8080/web/client` receives an HTTP response. If the service is Running but this fails, inspect SFTPGo logs and AhnLab HIPS history.
- [ ] `Get-NetTCPConnection -State Listen -LocalPort 2022` returns nothing; SFTP, FTP, and SFTPGo WebDAV are disabled.
- [ ] `Get-NetFirewallRule -Name HomeData-SMB-LAN | Get-NetFirewallAddressFilter` shows local `192.168.0.20` and remote `192.168.0.0/24`.
- [ ] `Get-NetConnectionProfile` still shows the physical LAN adapters as Public; the narrow `HomeData-SMB-LAN` rule works without broadly trusting either network.
- [ ] Existing `Tailscale-In (v4)` remains scoped to local `100.95.190.99`. SFTPGo has no listener on that address, so peers can reach only Tailscale Serve, not backend ports 8080/8081 directly.
- [ ] `Get-SmbShare -Name Data | Format-List Name,Path,EncryptData,CachingMode` shows the expected path, encryption, and no offline caching.
- [ ] `(& 'C:\Program Files\Tailscale\tailscale.exe' status --json | ConvertFrom-Json).CertDomains` is non-empty. If empty, private HTTP/raw TCP Serve can work but HTTPS Serve cannot.
- [ ] `& 'C:\Program Files\Tailscale\tailscale.exe' serve status` shows HTTPS forwarding to `http://127.0.0.1:8080` and does not say Funnel.
- [ ] `Invoke-WebRequest -UseBasicParsing http://127.0.0.1:8081/web/admin` reaches WebAdmin; attempting `http://192.168.0.20:8081` fails.
- [ ] `powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE` shows AC timeout `0`.

### From LAN PC `pyu-book6`

- [ ] `Test-NetConnection 192.168.0.20 -Port 445` succeeds.
- [ ] `Test-NetConnection 192.168.0.18 -Port 445` does not provide usable share access; the approved path is `.20` only.
- [ ] Map `Z:` with the command above, create the E2E file, edit it, close it, and read it back.
- [ ] On the server, `Get-SmbSession` shows the LAN client and `Get-SmbConnection` on the client reports dialect `3.x`, signed/encrypted as configured.
- [ ] With Tailscale connected, the HTTPS WebClient URL opens and the device-specific SFTPGo user can see the same E2E file.

### From remote Windows PC `pyu-sjc-main`

- [ ] Move it off the home LAN (phone hotspot is a valid test), connect Tailscale, and run `tailscale ping hjyuhomemain`; it succeeds either direct or relayed.
- [ ] `https://hjyuhomemain.tail80e577.ts.net/web/client` has a valid browser certificate and accepts only the SFTPGo user, not the Windows/Entra password.
- [ ] Download the LAN-created E2E file, upload a second file, rename it, and confirm that change on `Z:` at home.
- [ ] Optional Windows-only proof: `Test-NetConnection 100.95.190.99 -Port 445` succeeds because the existing Tailscale firewall rule permits it; `net use` with `HJYUHomeMain\shareuser` then proves the new credential fixes the previously measured authentication failure. Keep WebClient as the primary remote path.
- [ ] Disconnect Tailscale and refresh: access fails. This proves the portal is private rather than Funnel/public ingress.
- [ ] Do not test or use public-IP ports 445 or 3389. A router-side scan should show neither forwarded.

### From Android browser

- [ ] On `s23-ultra`, turn off Wi-Fi so the test is genuinely external, connect the Tailscale Android VPN, and open the same HTTPS URL in Chrome/Firefox.
- [ ] Log in with the Android-specific SFTPGo account, preview/download the E2E file, upload a camera test image, and delete only the disposable test image.
- [ ] Lock/unlock the phone and repeat once to confirm Tailscale and the browser resume correctly.
- [ ] Disconnect Tailscale; the URL must stop loading. Reconnect and confirm it returns.

### Reboot and persistence proof

- [ ] Use **Restart** on `HJYUHomeMain` once and do not sign in for five minutes. Restart exercises a full boot even though Fast Startup is enabled; ordinary Shutdown/Power On may reuse hybrid-boot state.
- [ ] From another tailnet device, the HTTPS WebClient becomes reachable. This proves the SFTPGo service, Tailscale service, and `serve --bg` mapping do not depend on an interactive user session.
- [ ] From a LAN PC, the SMB drive reconnects and a read/write test succeeds.
- [ ] The server does not enter sleep during a two-hour idle period. Display-off is harmless; system sleep is not.

## Expected failure modes and responses

| Failure | Symptom | Correct response |
|---|---|---|
| Wrong data volume / Drive mirror intrusion | Setup sees `D:\.tmp.driveupload`, or a configured home/share resolves under `J:`. | Stop immediately. Do not serve a Google Drive mirror. Confirm `D:` is `DataAndETC`, remove no Drive metadata automatically, and correct every share/home path to `D:\SharedData`. |
| AhnLab V3 blocks install or executable | winget reports failure, `sftpgo.exe` disappears, service registration/start is denied, or V3 reports quarantine. | Review V3 detection history, confirm package `drakkan.SFTPGo` 2.7.3 and winget source/hash, update V3, then allow only the verified executable if it is a false positive. Never disable V3 globally. |
| AhnLab NIPS blocks a new listener/flow | Loopback WebClient works and Tailscale ping succeeds, but peer TCP 443 or SMB fails despite correct Windows Firewall rules. | Correlate `TNNipsNt`/V3 network-IPS events with `tailscale serve status`; add only a product-supported exact flow/program exception after validation. Do not create a broad Tailscale or `D:` exclusion. |
| Wired DHCP address changes | `Z:` cannot reconnect; `.20` is absent. | Fix the router reservation and restore `.20`. Do not broaden the firewall to both same-subnet adapters as a shortcut. |
| Dual-homed name resolution chooses Wi-Fi `.18` | Hostname SMB is intermittent while IP SMB works. | Keep using `\\192.168.0.20\Data`; disable Wi-Fi when not needed. Do not enable broad SMB firewall rules. |
| Host sleeps or is shut down | LAN and tailnet paths both time out. | Verify AC sleep is `Never`, BIOS “restore after AC loss” if desired, and scheduled updates/reboots. A desktop is not highly available. |
| Fast Startup hides a boot-only problem | Shutdown/Power On seems healthy but a true restart behaves differently, or vice versa. | Use Restart for service/autostart acceptance testing. Test a deliberate full shutdown separately if required; do not assume hybrid shutdown proves cold-boot behavior. |
| `D:` is absent/locked at boot | SFTPGo starts but file operations fail; SMB path is unavailable. | Auto-unlock the fixed data volume, then restart SFTPGo. Its service failure policy retries process failures, not a permanently missing disk. |
| Tailscale `CertDomains` is empty | Setup stops before configuring production Serve; `--https=443` cannot work. | As tailnet owner, enable **HTTPS Certificates** on the DNS page, wait for propagation, then rerun. Private HTTP/raw TCP Serve already work but are not the selected production browser endpoint. Do not add the Funnel node attribute. |
| MagicDNS/private DNS conflict on Android | Tailscale ping by IP works, `.ts.net` URL does not. | Enable Tailscale DNS/MagicDNS and remove a conflicting Android Private DNS/VPN for the test. Use the hostname for HTTPS; the `100.x` IP will not match the certificate. |
| SFTPGo brute-force defender bans a client | Correct login temporarily fails after repeated bad passwords. | Stop guessing, wait for the ban interval, then inspect local WebAdmin/logs. Because the trusted proxy is only loopback and X-Forwarded-For is honored, one client should not ban every client. |
| SFTPGo upgrade resets its Windows service to LocalSystem | Service `StartName` no longer shows `NT SERVICE\sftpgo`. | Review the new release, update the script’s pinned `--version`, rerun it, then verify service identity and loopback listeners. Upstream’s Windows installer re-registers the service on upgrades. |
| Simultaneous edits over SMB and WebClient | Last writer may overwrite content; Office-style application locking does not extend through an HTTP upload. | Do not edit the same file simultaneously through different protocols. SMB clients get SMB locking; browser users should download/edit/upload intentionally. |
| Large browser upload interrupted | Browser reports failure or a partial operation. | Retry through WebClient’s resumable upload support; atomic upload mode prevents an incomplete file from replacing the final name. Verify free space. |
| Password loss | SMB mapping or WebClient login fails. | An elevated server admin can reset `shareuser`; SFTPGo admin can reset only the affected application user. Distinct credentials limit impact. |
| Ransomware/client compromise | Accessible files are encrypted/deleted through a valid account. | Restore from offline/versioned backup and revoke that account/device. Neither SMB encryption nor Tailscale protects against an authorized malicious client. |
| Public reachability is later required | A user without Tailscale cannot open the portal. | Make a new, explicit exposure decision. Cloudflare Tunnel + Access works through current CGNAT. Funnel also traverses CGNAT but requires both certificate and ACL capability changes and creates public exposure. Caddy/DDNS/port-forward remains impossible unless KT first supplies a real public/static IP. Never expose 445/3389. |

## Rollback

Rollback preserves `D:\SharedData`. It removes access paths and restores the pre-change SFTPGo config and the exact TCP/445 allow-rule names recorded by setup. It does not try to reconstruct a prior power timeout from localized `powercfg` output; the saved snapshot is provided for manual comparison.

Save the following as `Rollback-HomeDataServer.ps1` and run it normally. It generates one UAC prompt. Review `$RemoveSftpGoIfNew` first.

```powershell
param([switch]$Elevated)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
$RemoveSftpGoIfNew = $true

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Elevated'
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Verb RunAs -ArgumentList $argLine -Wait -PassThru
    exit $proc.ExitCode
}

$statePath = 'C:\ProgramData\HomeDataServer\state.json'
if (-not (Test-Path -LiteralPath $statePath)) {
    throw "Rollback state is missing: $statePath"
}
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

& 'C:\Program Files\Tailscale\tailscale.exe' serve reset
Stop-Service -Name 'sftpgo' -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $state.SftpGoConfigBackup) {
    Copy-Item -LiteralPath $state.SftpGoConfigBackup `
        -Destination 'C:\ProgramData\SFTPGo\sftpgo.json' -Force
}
& sc.exe config sftpgo obj= LocalSystem password= '' start= auto | Out-Null
Start-Service -Name 'sftpgo' -ErrorAction SilentlyContinue

Remove-SmbShare -Name $state.ShareName -Force -ErrorAction SilentlyContinue
Remove-NetFirewallRule -Name 'HomeData-SMB-LAN' -ErrorAction SilentlyContinue
foreach ($ruleName in @($state.DisabledFirewallRuleNames)) {
    Enable-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue | Out-Null
}
if ($state.ShareUserCreated) {
    Remove-LocalUser -Name $state.ShareUser -ErrorAction SilentlyContinue
}

if ($RemoveSftpGoIfNew -and -not $state.SftpGoWasPresent) {
    Stop-Service -Name 'sftpgo' -Force -ErrorAction SilentlyContinue
    & winget.exe uninstall --id drakkan.SFTPGo --exact --source winget --silent
}

Write-Host 'Rollback complete. D:\SharedData was retained.' -ForegroundColor Green
Write-Host "Restore the previous AC sleep value using $($state.PowerConfigSnapshot) as reference."
Write-Host 'If you intentionally want NetBIOS again, re-enable it in the adapter IPv4 advanced WINS settings.'
```

After rollback, remove saved client credentials with `net use Z: /delete` on each PC. Deleting `C:\ProgramData\SFTPGo` is deliberately not automated because it contains the user database and recovery material. Delete it only after making a backup and confirming SFTPGo will not be restored. Likewise, never delete `D:\SharedData` as part of application rollback.

## Operational rules

- Patch Windows, Tailscale, and SFTPGo regularly. For SFTPGo, review the release, update the pinned winget version in this script, and rerun it because the installer can restore the service identity to LocalSystem.
- Back up both `D:\SharedData` and `C:\ProgramData\SFTPGo`; test restoring a file and the SFTPGo database.
- Keep the tailnet account protected with MFA and remove lost devices promptly. Use Tailscale access policy if the tailnet later gains users who should not reach this server.
- Keep router UPnP limited/disabled where practical and audit mappings, but recognize that ipTIME mappings alone cannot cross the measured upstream KT CGNAT.
- Treat public sharing as a separate future project. The selected design has zero intentional public inbound ports.
