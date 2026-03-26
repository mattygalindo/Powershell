function Invoke-AdluminRestart {

Import-Module Posh-SSH

$ip = Read-Host "Enter device IP or hostname"
$username = Read-Host "Enter SSH username"
$securePassword = Read-Host "Enter SSH password" -AsSecureString
$credential = New-Object System.Management.Automation.PSCredential ($username, $securePassword)

function Read-UntilPrompt {
    param (
        [Parameter(Mandatory = $true)]
        $Stream,

        [int]$TimeoutSeconds = 30
    )

    $output = ""
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopWatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 500
        $chunk = $Stream.Read()
        if ($chunk) {
            $output += $chunk

            # Match a typical Linux shell prompt ending in $ or #
            if ($output -match '(\r?\n|^).+[@].+[#$]\s*$') {
                break
            }
        }
    }

    return $output
}

function Send-CommandAndHandleSudoPrompt {
    param (
        [Parameter(Mandatory = $true)]
        $Stream,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [int]$TimeoutSeconds = 60
    )

    Write-Host ""
    Write-Host "Running: $Command" -ForegroundColor Yellow
    $Stream.WriteLine($Command)

    $output = ""
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $passwordSent = $false

    while ($stopWatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 500
        $chunk = $Stream.Read()

        if ($chunk) {
            $output += $chunk

            if (-not $passwordSent -and $output -match '[Pp]assword') {
                Write-Host ""
                Write-Host "Remote system is prompting for sudo password." -ForegroundColor Cyan
                $sudoSecurePassword = Read-Host "Enter sudo password" -AsSecureString

                $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sudoSecurePassword)
                try {
                    $sudoPlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
                    $Stream.WriteLine($sudoPlainPassword)
                    $passwordSent = $true
                }
                finally {
                    if ($ptr -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
                    }
                }
            }

            # Wait until shell prompt comes back
            if ($output -match '(\r?\n|^).+[@].+[#$]\s*$') {
                break
            }
        }
    }

    return $output
}

try {
    Write-Host ""
    Write-Host "Connecting to $ip ..." -ForegroundColor Cyan

    $session = New-SSHSession `
        -ComputerName $ip `
        -Credential $credential `
        -AcceptKey `
        -ErrorAction Stop

    if (-not $session) {
        throw "SSH session could not be established."
    }

    Write-Host "SSH connection established." -ForegroundColor Green
    Write-Host "Session ID: $($session.SessionId)"

    $stream = New-SSHShellStream -SessionId $session.SessionId

    # Read initial prompt/banner
    $initialOutput = Read-UntilPrompt -Stream $stream -TimeoutSeconds 10
    if ($initialOutput) {
        Write-Host ""
        Write-Host "Initial Shell Output:" -ForegroundColor DarkGray
        Write-Host $initialOutput
    }

    # Step 1 - Restart DNS resolver
    $dnsOutput = Send-CommandAndHandleSudoPrompt -Stream $stream -Command "sudo systemctl restart systemd-resolved" -TimeoutSeconds 30
    Write-Host ""
    Write-Host "systemd-resolved Restart Output:" -ForegroundColor Green
    Write-Host $dnsOutput

    # Step 2 - Initial status
    $statusBefore = Send-CommandAndHandleSudoPrompt -Stream $stream -Command "adlumin_status" -TimeoutSeconds 30
    Write-Host ""
    Write-Host "adlumin_status Output (Before Restart):" -ForegroundColor Green
    Write-Host $statusBefore

    # Step 3 - Restart Adlumin
    $restartOutput = Send-CommandAndHandleSudoPrompt -Stream $stream -Command "sudo adlumin_restart" -TimeoutSeconds 90
    Write-Host ""
    Write-Host "adlumin_restart Output:" -ForegroundColor Green
    Write-Host $restartOutput

    # Optional short wait after restart
    Write-Host ""
    Write-Host "Waiting 5 seconds before checking status again..." -ForegroundColor Cyan
    Start-Sleep -Seconds 5

    # Step 4 - Final status
    $statusAfter = Send-CommandAndHandleSudoPrompt -Stream $stream -Command "adlumin_status" -TimeoutSeconds 30
    Write-Host ""
    Write-Host "adlumin_status Output (After Restart):" -ForegroundColor Green
    Write-Host $statusAfter
}
catch {
    Write-Host ""
    Write-Host "Connection or command execution failed:" -ForegroundColor Red
    Write-Host $_.Exception.Message
}
finally {
    if ($session) {
        Write-Host ""
        Write-Host "Closing SSH session..." -ForegroundColor Yellow
        Remove-SSHSession -SessionId $session.SessionId | Out-Null
        Write-Host "Session closed." -ForegroundColor Green
    }
}

}
