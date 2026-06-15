param(
  [Parameter(Mandatory = $true)]
  [string]$HostName,
  [int]$Port = 22,
  [Parameter(Mandatory = $true)]
  [string]$User,
  [string]$IdentityFile = "",
  [string]$LocalProxyHost = "127.0.0.1",
  [int]$LocalProxyPort = 7890,
  [int]$RemoteTunnelPort = 17890,
  [string]$RemoteForwardBind = "127.0.0.1",
  [int]$RemoteForwardPort = 17891
)

$ErrorActionPreference = "Stop"

$target = "{0}@{1}" -f $User, $HostName
$sshArgs = @("-p", "$Port", "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=30")
$scpArgs = @("-P", "$Port", "-o", "StrictHostKeyChecking=accept-new")
if ($IdentityFile) {
  $sshArgs += @("-i", $IdentityFile, "-o", "IdentitiesOnly=yes")
  $scpArgs += @("-i", $IdentityFile, "-o", "IdentitiesOnly=yes")
}

$reverseSpec = "127.0.0.1:{0}:{1}:{2}" -f $RemoteTunnelPort, $LocalProxyHost, $LocalProxyPort
$existingTunnel = Get-CimInstance Win32_Process -Filter "name='ssh.exe'" |
  Where-Object { $_.CommandLine -like "*$HostName*" -and $_.CommandLine -like "*$RemoteTunnelPort*" -and $_.CommandLine -like "*$LocalProxyPort*" }

if (-not $existingTunnel) {
  $args = $sshArgs + @("-o", "ExitOnForwardFailure=yes", "-N", "-R", $reverseSpec, $target)
  Start-Process -FilePath "ssh" -ArgumentList $args -WindowStyle Hidden
  Start-Sleep -Seconds 2
}

$forwarder = @"
import select
import socket
import threading

LISTEN = ("$RemoteForwardBind", $RemoteForwardPort)
TARGET = ("127.0.0.1", $RemoteTunnelPort)

def relay(client):
    upstream = None
    try:
        upstream = socket.create_connection(TARGET, timeout=10)
        sockets = [client, upstream]
        while True:
            readable, _, _ = select.select(sockets, [], [], 60)
            for sock in readable:
                data = sock.recv(65536)
                if not data:
                    return
                (upstream if sock is client else client).sendall(data)
    except Exception:
        return
    finally:
        try:
            client.close()
        except Exception:
            pass
        if upstream is not None:
            try:
                upstream.close()
            except Exception:
                pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(LISTEN)
server.listen(128)
print(f"ai_gateway_proxy_forwarder ready {LISTEN} -> {TARGET}", flush=True)
while True:
    client, _ = server.accept()
    threading.Thread(target=relay, args=(client,), daemon=True).start()
"@

$localForwarder = Join-Path $env:TEMP ("ai-gateway-proxy-forwarder-{0}.py" -f $RemoteForwardPort)
$remoteForwarder = "/tmp/ai-gateway-proxy-forwarder-{0}.py" -f $RemoteForwardPort
$remoteLog = "/tmp/ai-gateway-proxy-forwarder-{0}.log" -f $RemoteForwardPort

try {
  [System.IO.File]::WriteAllText($localForwarder, $forwarder, [System.Text.Encoding]::ASCII)
  scp @scpArgs $localForwarder "${target}:$remoteForwarder"
  $remote = "if ss -ltn 2>/dev/null | grep -q ':$RemoteForwardPort '; then ss -ltnp 2>/dev/null | grep $RemoteForwardPort || true; else nohup python3 $remoteForwarder >$remoteLog 2>&1 & sleep 1; ss -ltnp 2>/dev/null | grep $RemoteForwardPort || { echo FORWARDER_LOG; tail -50 $remoteLog; exit 1; }; fi"
  ssh @sshArgs $target $remote
} finally {
  if (Test-Path $localForwarder) {
    Remove-Item -LiteralPath $localForwarder -Force
  }
}

Write-Host ("Outbound proxy ready: http://{0}:{1}" -f $RemoteForwardBind, $RemoteForwardPort)
