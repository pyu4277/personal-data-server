#requires -Version 5.1
<#
  개인 서버 네트워크 드라이브 연결 - 배포본
  ==========================================
  버전 : 2.0  (2026-08-19)
  대상 : 개인 서버에 접속할 Windows PC (pyu-book6, pyu-sjc-main 등)
  전제 : 해당 PC에 Tailscale 이 설치되어 있고 같은 계정으로 로그인되어 있을 것
  실행 : "개인서버 연결하기.bat" 더블클릭 (관리자 승격 자동)

  설계 원칙
    - 표시 이름을 먼저 등록한 뒤 딱 한 번만 연결한다.
      (연결 후 이름을 바꾸려고 재연결하면 Windows 오류 1219 가 난다)
    - 같은 서버로 향하는 기존 연결은 전부 정리한 뒤 시작한다.
    - 드라이브 문자는 실제 사용 여부를 4개 소스에서 교차 확인해 고른다.
    - 어떤 단계가 실패해도 시스템을 반쯤 망가진 상태로 남기지 않는다.
    - 몇 번을 다시 실행해도 같은 결과가 된다 (멱등).

  되돌리기 : 같은 명령에 -Uninstall 을 붙여 실행
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[D-Zd-z]$')]
    [string]$DriveLetter = 'S',
    [string]$Server      = 'hjyuhomemain',
    [string]$Share       = 'Data',
    [string]$Label       = '개인서버',
    [string]$ShareUser   = 'HJYUHomeMain\shareuser',
    [string]$IconPath    = "$env:SystemRoot\System32\imageres.dll,30",
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$VERSION  = '2.0'
$Unc      = "\\$Server\$Share"
$Dl       = $DriveLetter.ToUpper()
$TaskName = 'PersonalServer-Remap'
$LogDir   = Join-Path $env:LOCALAPPDATA 'PersonalServer'
$null     = New-Item -ItemType Directory -Path $LogDir -Force
$LogFile  = Join-Path $LogDir ('connect-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')

$script:Lines = New-Object System.Collections.Generic.List[string]
function Say  { param([string]$s) [void]$script:Lines.Add($s); Write-Host $s }
function Warn { param([string]$s) [void]$script:Lines.Add('[경고] ' + $s); Write-Host ('[경고] ' + $s) -ForegroundColor Yellow }
function Good { param([string]$s) [void]$script:Lines.Add('[OK] ' + $s);  Write-Host ('  ' + $s) -ForegroundColor Green }
function SaveLog { [IO.File]::WriteAllText($LogFile, ($script:Lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true))) }

# ═══════════════════════════════════════════════════════════ 공용 도우미

# PowerShell 5.1 함정 대응.
# $ErrorActionPreference = 'Stop' 상태에서 네이티브 exe 에 2>&1 / 2>$null 을 쓰면
# stderr 한 줄이 ErrorRecord 로 변환되어 종료 오류가 된다.
# net.exe 는 "끊을 연결이 없음" 같은 정상 상황에도 stderr 에 쓰므로 반드시 감싼다.
function Invoke-Quiet {
    param([string]$CommandLine)
    $null = & cmd.exe /c ($CommandLine + ' >nul 2>&1')
    return $LASTEXITCODE
}
function Invoke-Capture {
    param([string]$CommandLine)
    return @(& cmd.exe /c ($CommandLine + ' 2>nul'))
}
function Invoke-Net {
    # net.exe 를 실행하고 종료코드와 메시지를 함께 돌려준다.
    param([string]$Arguments)
    $o = @(& cmd.exe /c ('net ' + $Arguments + ' 2>&1'))
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (($o | Where-Object { $_ -match '\S' }) -join ' ').Trim() }
}

function Get-UsedDriveLetters {
    # Get-SmbMapping 만 보면 로컬 파티션 / subst / 다른 세션 매핑을 놓쳐 오류 85 가 난다.
    $used = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Name.Length -eq 1) { [void]$used.Add($d.Name.ToUpper()) }
    }
    foreach ($v in (Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        if ($v.DeviceID -match '^([A-Za-z]):') { [void]$used.Add($Matches[1].ToUpper()) }
    }
    foreach ($m in (Get-SmbMapping -ErrorAction SilentlyContinue)) {
        if ($m.LocalPath -match '^([A-Za-z]):') { [void]$used.Add($Matches[1].ToUpper()) }
    }
    foreach ($line in (Invoke-Capture 'net use')) {
        if ($line -match '\s([A-Za-z]):\s') { [void]$used.Add($Matches[1].ToUpper()) }
    }
    return $used
}

function Clear-ServerConnections {
    # 같은 서버로 향하는 모든 연결을 끊는다. 오류 1219 의 유일한 근본 대책.
    # 대상은 이 서버로 한정된다. 다른 공유(회사 서버 등)는 절대 건드리지 않는다.
    param([string]$Srv, [string]$Target)
    $found = @(Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.RemotePath -like "\\$Srv\*" })
    $letter = $null
    foreach ($m in $found) {
        if ($m.RemotePath -eq $Target -and $m.LocalPath -match '^([A-Za-z]):') { $letter = $Matches[1].ToUpper() }
        Say ("  기존 연결 해제 : " + $m.LocalPath + '  ->  ' + $m.RemotePath)
        Remove-SmbMapping -LocalPath $m.LocalPath -Force -ErrorAction SilentlyContinue
    }
    # 드라이브 문자가 없는 잔여 세션(IPC$ 등)까지 끊는다.
    # 끊을 것이 없으면 net.exe 가 stderr 에 쓰므로 반드시 Invoke-Quiet 로 감싼다.
    $null = Invoke-Quiet ('net use "' + $Target + '" /d /y')
    $null = Invoke-Quiet ('net use "\\' + $Srv + '\IPC$" /d /y')
    Start-Sleep -Milliseconds 800
    return $letter
}

# ═══════════════════════════════════════════════════════════ 되돌리기 모드
if ($Uninstall) {
    Say "===== 개인 서버 연결 해제 (v$VERSION) ====="

    # 끊어야 할 드라이브 문자를 먼저 확인해 둔다 (일반 세션 정리에 필요).
    $letters = @()
    foreach ($k in (Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
        $rp = (Get-ItemProperty $k.PSPath -Name RemotePath -ErrorAction SilentlyContinue).RemotePath
        if ($rp -like "\\$Server\*") { $letters += $k.PSChildName.ToUpper() }
    }
    foreach ($m in (Get-SmbMapping -ErrorAction SilentlyContinue | Where-Object { $_.RemotePath -like "\\$Server\*" })) {
        if ($m.LocalPath -match '^([A-Za-z]):') { $letters += $Matches[1].ToUpper() }
    }
    $letters = @($letters | Sort-Object -Unique)

    $null = Clear-ServerConnections -Srv $Server -Target $Unc
    Good '네트워크 연결 해제 완료 (승격 세션)'

    # UAC 토큰 분리 때문에, 승격 세션에서의 해제만으로는 사용자의 일반 세션 연결이 남는다.
    # 설치 때와 대칭으로, 일반 권한 일회성 작업을 만들어 실행한 뒤 지운다.
    if ($letters.Count -gt 0) {
        $tmpTask = 'PersonalServer-Cleanup'
        try {
            $dcmd = ($letters | ForEach-Object { "net use ${_}: /d /y" }) -join '; '
            $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "' + $dcmd + '"')
            $tr = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
            Unregister-ScheduledTask -TaskName $tmpTask -Confirm:$false -ErrorAction SilentlyContinue
            $null = Register-ScheduledTask -TaskName $tmpTask -Action $a -Trigger $tr -RunLevel Limited `
                    -Description '개인 서버 연결 정리 (일회성)'
            Start-ScheduledTask -TaskName $tmpTask -ErrorAction Stop
            Start-Sleep -Seconds 5
            Unregister-ScheduledTask -TaskName $tmpTask -Confirm:$false -ErrorAction SilentlyContinue
            Good ('네트워크 연결 해제 완료 (일반 세션) : ' + (($letters | ForEach-Object { $_ + ':' }) -join ', '))
        } catch {
            Warn ('일반 세션 정리 실패. 일반 PowerShell 에서 다음을 실행하세요 : ' + (($letters | ForEach-Object { "net use ${_}: /d /y" }) -join ' ; '))
        }
    }

    $null = Invoke-Quiet ('cmdkey /delete:' + $Server)
    Good '저장된 자격증명 삭제'

    $mp2 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##$Server#$Share"
    Remove-Item -Path $mp2 -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($c in [char[]]'DEFGHIJKLMNOPQRSTUVWXYZ') {
        Remove-Item -Path "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$c" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Good '표시 이름 / 아이콘 설정 제거'

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Good '로그온 재연결 작업 제거'

    Say ''
    Say '되돌리기 완료. EnableLinkedConnections 와 로컬 드라이브는 건드리지 않았습니다.'
    SaveLog
    return
}

# ═══════════════════════════════════════════════════════════ 0. 사전 점검
Say "═══════════════════════════════════════════════════"
Say " 개인 서버 드라이브 연결  v$VERSION"
Say "═══════════════════════════════════════════════════"
Say ''
Say '[1/7] 사전 점검'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say ''
    Say '  관리자 권한이 필요합니다.'
    Say '  "개인서버 연결하기.bat" 을 더블클릭하면 자동으로 승격됩니다.'
    SaveLog
    throw '관리자 권한 없음'
}
Good "관리자 권한"

$tsExe = 'C:\Program Files\Tailscale\tailscale.exe'
if (-not (Test-Path $tsExe)) {
    Say ''
    Say '  Tailscale 이 설치되어 있지 않습니다.'
    Say '  https://tailscale.com/download 에서 설치하고 같은 계정으로 로그인한 뒤 다시 실행하세요.'
    SaveLog
    throw 'Tailscale 미설치'
}
$tsState = try {
    ((Invoke-Capture ('"' + $tsExe + '" status --json')) -join "`n" | ConvertFrom-Json).BackendState
} catch { 'Unknown' }
if ($tsState -ne 'Running') {
    Say ''
    Say "  Tailscale 상태가 '$tsState' 입니다. 연결되어 있지 않습니다."
    Say '  작업표시줄 Tailscale 아이콘에서 로그인한 뒤 다시 실행하세요.'
    SaveLog
    throw 'Tailscale 미연결'
}
Good "Tailscale : Running"

# 서버 본인에서 실행하면 SMB 루프백이라 자격증명이 무시되고 현재 사용자 토큰이 쓰인다.
# 그 결과 비승격 세션에서 "액세스 거부" 가 나므로, 아예 실행하지 않도록 막는다.
if ($env:COMPUTERNAME -ieq $Server -or $env:COMPUTERNAME -ieq ($Server -split '\.')[0]) {
    Say ''
    Say "  이 PC 가 서버($Server) 본인입니다."
    Say '  서버에서는 네트워크 드라이브가 필요 없습니다. D:\ 를 그대로 쓰세요.'
    Say '  (자기 자신에게 SMB 로 붙으면 자격증명이 무시되어 접근이 거부됩니다)'
    SaveLog
    return
}

$probe = Test-NetConnection -ComputerName $Server -Port 445 -WarningAction SilentlyContinue
if (-not $probe.TcpTestSucceeded) {
    Say ''
    Say "  서버 '$Server' 의 SMB(445) 에 연결할 수 없습니다."
    Say '  서버 PC 가 켜져 있고 Tailscale 에 연결되어 있는지 확인하세요.'
    SaveLog
    throw '서버 도달 불가'
}
Good ("서버 도달 : $Server  ($($probe.RemoteAddress))")

# ═══════════════════════════════════════════════════════════ 1. 자격증명
Say ''
Say '[2/7] 자격증명 저장'
Say "  계정 : $ShareUser"
Say '  비밀번호는 서버 PC 의 C:\ProgramData\HomeDataServer\credentials.txt 의 SMB_PASSWORD 값입니다.'
$sec = Read-Host -Prompt '  비밀번호' -AsSecureString
if ($sec.Length -eq 0) { SaveLog; throw '비밀번호가 입력되지 않았습니다.' }
$bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

# 오래된 항목이 남아 있으면 인증이 조용히 실패한다. 반드시 지우고 새로 넣는다.
$null = Invoke-Quiet ('cmdkey /delete:' + $Server)
$null = & cmdkey.exe /add:$Server /user:$ShareUser /pass:$plain
if ($LASTEXITCODE -ne 0) { SaveLog; throw 'cmdkey 자격증명 저장 실패' }
Good '자격 증명 관리자에 저장'

# ═══════════════════════════════════════════════════════════ 2. 기존 연결 정리
Say ''
Say '[3/7] 기존 연결 정리'
$prevLetter = Clear-ServerConnections -Srv $Server -Target $Unc
if ($prevLetter) {
    $Dl = $prevLetter
    Good "이전에 쓰던 문자 ${Dl}: 를 그대로 유지합니다"
} else {
    Good '정리 완료'
}

# ═══════════════════════════════════════════════════════════ 3. 드라이브 문자 결정
Say ''
Say '[4/7] 드라이브 문자 결정'
$used = Get-UsedDriveLetters
Say ('  사용 중 : ' + (($used | Sort-Object) -join ', '))
if ($used.Contains($Dl)) {
    $v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${Dl}:'" -ErrorAction SilentlyContinue
    $what = if ($v) { '로컬 볼륨 ' + $v.VolumeName + ' (' + [math]::Round($v.Size/1GB,1) + ' GB)' } else { '용도 불명' }
    Warn "${Dl}: 는 이미 사용 중입니다 - $what"
    $picked = $null
    foreach ($c in [char[]]'STUVWXYZRQPONM') {
        if (-not $used.Contains([string]$c)) { $picked = [string]$c; break }
    }
    if (-not $picked) { SaveLog; throw '사용 가능한 드라이브 문자가 없습니다.' }
    $Dl = $picked
}
Good "사용할 문자 : ${Dl}:"

# ═══════════════════════════════════════════════════════════ 4. 표시 설정 (연결 전에!)
Say ''
Say '[5/7] 표시 이름과 아이콘 등록'
# 매핑된 네트워크 드라이브의 이름은 MountPoints2 의 _LabelFromReg 만 반영된다.
# 그리고 이 값은 "연결이 맺어지는 순간" 읽히므로 반드시 매핑 전에 써야 한다.
$mp2 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##$Server#$Share"
$null = New-Item -Path $mp2 -Force
$null = New-ItemProperty -Path $mp2 -Name '_LabelFromReg' -Value $Label -PropertyType String -Force
Good "표시 이름 : $Label"

$drvKey = "HKCU:\Software\Classes\Applications\Explorer.exe\Drives\$Dl"
$null = New-Item -Path "$drvKey\DefaultIcon"  -Force
$null = New-Item -Path "$drvKey\DefaultLabel" -Force
Set-ItemProperty -Path "$drvKey\DefaultIcon"  -Name '(default)' -Value $IconPath
Set-ItemProperty -Path "$drvKey\DefaultLabel" -Name '(default)' -Value $Label
Good "아이콘 : $IconPath"

# ═══════════════════════════════════════════════════════════ 5. 연결 (단 한 번)
Say ''
Say '[6/7] 드라이브 연결'
# New-SmbMapping 이 아니라 net use 를 쓴다.
# New-SmbMapping -Persistent 는 HKCU\Network 에 항목을 남기지 않아,
# 승격 세션에서 만들면 사용자의 일반 탐색기에 드라이브가 나타나지 않는다.
# net use /persistent:yes 는 HKCU\Network 를 확실히 기록하므로 양쪽 세션에서 보인다.
$mapped = $false
$r = Invoke-Net ('use ' + $Dl + ': "' + $Unc + '" /persistent:yes')
if ($r.Code -eq 0) {
    $mapped = $true
    Good "연결 완료 : ${Dl}: -> $Unc  (저장된 자격증명, 영구)"
} else {
    Warn ('저장된 자격증명으로 실패 : ' + $r.Text)
    $r2 = Invoke-Net ('use ' + $Dl + ': "' + $Unc + '" "' + $plain + '" /user:"' + $ShareUser + '" /persistent:yes')
    if ($r2.Code -eq 0) {
        $mapped = $true
        Good "연결 완료 : ${Dl}: -> $Unc  (명시적 자격증명, 영구)"
    } else {
        $msg = $r2.Text
        Say ''
        Say "  연결에 실패했습니다 : $msg"
        if ($msg -match '1326|1327|로그온|암호')  { Say '  -> 비밀번호가 틀렸을 가능성이 높습니다. credentials.txt 의 SMB_PASSWORD 를 확인하세요.' }
        if ($msg -match '1219')                    { Say '  -> 이 PC 를 재부팅한 뒤 다시 실행하면 해결됩니다.' }
        if ($msg -match '85|이미 사용')            { Say "  -> ${Dl}: 가 이미 쓰이고 있습니다. -DriveLetter 로 다른 문자를 지정해 보세요." }
        $plain = $null
        SaveLog
        throw '드라이브 연결 실패'
    }
}
$plain = $null

# HKCU\Network 기록 확인 - 이게 있어야 일반 세션 탐색기에 나타난다.
if (Test-Path "HKCU:\Network\$Dl") {
    Good 'HKCU\Network 영구 기록 확인 (일반 세션에서도 표시됨)'
} else {
    Warn 'HKCU\Network 기록이 없습니다. 로그오프 후 다시 로그인하면 나타납니다.'
}

# ═══════════════════════════════════════════════════════════ 6. 부가 설정
Say ''
Say '[7/7] 부가 설정'

# (a) 관리자 권한 프로그램에서도 매핑 드라이브가 보이게 한다 (재부팅 후 적용)
$sysKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$cur = (Get-ItemProperty -Path $sysKey -Name 'EnableLinkedConnections' -ErrorAction SilentlyContinue).EnableLinkedConnections
if ($cur -eq 1) { Good 'EnableLinkedConnections : 이미 설정됨' }
else {
    Set-ItemProperty -Path $sysKey -Name 'EnableLinkedConnections' -Type DWord -Value 1
    Good 'EnableLinkedConnections : 설정 (재부팅 후 적용)'
}

# (b) 로그온 직후에는 네트워크와 Tailscale 이 아직 올라오지 않아 연결이 끊긴 것처럼 보인다.
#     로그온 1분 뒤 한 번 더 확인해 빨간 X 를 없앤다.
try {
    $cmd     = "if (-not (Test-Path '${Dl}:\')) { net use ${Dl}: $Unc /persistent:yes }"
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    try { $trigger.Delay = 'PT1M' } catch { }
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $set `
            -Description '개인 서버 네트워크 드라이브 재연결' -RunLevel Limited
    Good "로그온 재연결 작업 등록 : $TaskName"

    # (c) UAC 토큰 분리 때문에, 승격 상태로 맺은 연결은 사용자의 일반 탐색기에서
    #     "사용할 수 없음" 으로 보인다. 방금 만든 작업은 일반 권한(RunLevel Limited)으로
    #     돌기 때문에, 지금 한 번 실행하면 재부팅 없이 바로 쓸 수 있게 된다.
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Start-Sleep -Seconds 6
    Good '일반 사용자 세션에 즉시 연결 (재부팅 없이 사용 가능)'
} catch {
    Warn ('로그온 재연결 작업 등록 실패 (연결 자체에는 지장 없음) : ' + $_.Exception.Message)
}

# ═══════════════════════════════════════════════════════════ 검증
Say ''
Say '───── 검증 ─────'
$readOk = $false; $writeOk = $false
if (Test-Path "${Dl}:\") {
    $readOk = $true
    Good "읽기 : ${Dl}:\ 접근 가능"
    $names = @(Get-ChildItem "${Dl}:\" -Force -ErrorAction SilentlyContinue | Select-Object -First 6 -ExpandProperty Name)
    if ($names.Count -gt 0) { Say ('  내용 : ' + ($names -join ', ')) }
    $tf = "${Dl}:\_conn_test_$PID.txt"
    try {
        [IO.File]::WriteAllText($tf, "ok $(Get-Date -Format s)")
        $null = [IO.File]::ReadAllText($tf)
        [IO.File]::Delete($tf)
        $writeOk = $true
        Good '쓰기 / 읽기 / 삭제 : 정상'
    } catch { Warn ('쓰기 테스트 실패 : ' + $_.Exception.Message) }
} else {
    Warn "${Dl}:\ 에 접근할 수 없습니다."
}

# 탐색기 재시작 - 표시 이름과 아이콘을 즉시 반영
Say ''
Say '  탐색기를 재시작해 표시를 갱신합니다 (열려 있던 프로그램은 유지됩니다)'
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }

# ═══════════════════════════════════════════════════════════ 요약
Say ''
Say '═══════════════════════════════════════════════════'
if ($mapped -and $readOk -and $writeOk) {
    Say " 완료 - 내 PC 에서 [$Label (${Dl}:)] 로 사용하세요."
} elseif ($mapped) {
    Say " 연결은 되었으나 일부 검증이 실패했습니다. 위 [경고] 를 확인하세요."
}
Say ''
Say " 드라이브     : ${Dl}:  ->  $Unc"
Say " 표시 이름    : $Label"
Say " 재부팅 필요  : 관리자 권한 프로그램에서 드라이브를 보려면 1회"
Say " 되돌리기     : 같은 명령에 -Uninstall 추가"
Say " 로그         : $LogFile"
Say '═══════════════════════════════════════════════════'
SaveLog
