param(
    [string]$ServerIp = "147.182.160.52",
    [string]$User = "root",
    [int]$Port = 7000,
    [string]$AdminFile = "/root/enders_admin_commands.txt"
)

$Remote = "$User@$ServerIp"
$Script:AdminKey = ""

function Invoke-Remote {
    param([string]$Command)
    ssh $Remote $Command
}

function Show-Logs {
    Invoke-Remote "tmux capture-pane -t gameserver -p -S -100 2>/dev/null || echo 'gameserver tmux session not found.'"
}

function Send-AdminCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Command + "`n")
    $payload = [Convert]::ToBase64String($bytes)
    Invoke-Remote "printf '%s' '$payload' | base64 -d >> '$AdminFile'"
    Start-Sleep -Milliseconds 700
    Show-Logs
}

function Prompt-Rules {
    $minPlayers = Read-Host "Min players to start [2]"
    if ([string]::IsNullOrWhiteSpace($minPlayers)) { $minPlayers = "2" }

    $startingCash = Read-Host "Starting cash [200000]"
    if ([string]::IsNullOrWhiteSpace($startingCash)) { $startingCash = "200000" }

    $pointsToWin = Read-Host "Points to win [8]"
    if ([string]::IsNullOrWhiteSpace($pointsToWin)) { $pointsToWin = "8" }

    $roundTime = Read-Host "Round time seconds, 0 means no limit [0]"
    if ([string]::IsNullOrWhiteSpace($roundTime)) { $roundTime = "0" }

    $map = Read-Host "Map: designed, core, module_station, asteroid_field, default_arena_3 [designed]"
    if ([string]::IsNullOrWhiteSpace($map)) { $map = "designed" }

    $seed = Read-Host "Map seed [1]"
    if ([string]::IsNullOrWhiteSpace($seed)) { $seed = "1" }

    $Script:AdminKey = Read-Host "In-game admin key, blank disables in-game admin"

    return @{
        MinPlayers = $minPlayers
        StartingCash = $startingCash
        PointsToWin = $pointsToWin
        RoundTime = $roundTime
        Map = $map
        Seed = $seed
    }
}

function Start-ServerWithRules {
    $rules = Prompt-Rules
    $adminAssignment = ""

    if (-not [string]::IsNullOrWhiteSpace($Script:AdminKey)) {
        $adminAssignment = "ADMIN_KEY='$Script:AdminKey' "
    }

    $command = (
        $adminAssignment +
        "MIN_PLAYERS='$($rules.MinPlayers)' " +
        "STARTING_CASH='$($rules.StartingCash)' " +
        "POINTS_TO_WIN='$($rules.PointsToWin)' " +
        "ROUND_TIME='$($rules.RoundTime)' " +
        "MAP='$($rules.Map)' " +
        "MAP_SEED='$($rules.Seed)' " +
        "ADMIN_FILE='$AdminFile' " +
        "/root/run_server.sh $Port"
    )

    Invoke-Remote $command
}

function Upload-LatestBuild {
    if (-not (Test-Path "build\enders_server.x86_64")) {
        Write-Host "Missing build\enders_server.x86_64. Export the Linux server build first." -ForegroundColor Yellow
        return
    }

    scp "build\enders_server.x86_64" "${Remote}:/root/"
    scp "run_server.sh" "${Remote}:/root/"
}

while ($true) {
    Write-Host ""
    Write-Host "Enders Server Control - $Remote" -ForegroundColor Cyan
    Write-Host "1. Monitor live console"
    Write-Host "2. Show latest logs"
    Write-Host "3. Send admin command"
    Write-Host "4. Start/restart with rules"
    Write-Host "5. Upload latest Linux build"
    Write-Host "6. Upload latest Linux build and restart"
    Write-Host "7. Stop server"
    Write-Host "8. Quit"

    $choice = Read-Host "Choose"

    switch ($choice) {
        "1" {
            ssh -t $Remote "tmux attach -t gameserver"
        }
        "2" {
            Show-Logs
        }
        "3" {
            $command = Read-Host "Admin command"
            Send-AdminCommand $command
        }
        "4" {
            Start-ServerWithRules
        }
        "5" {
            Upload-LatestBuild
        }
        "6" {
            Upload-LatestBuild
            Start-ServerWithRules
        }
        "7" {
            Invoke-Remote "tmux kill-session -t gameserver 2>/dev/null || true"
        }
        "8" {
            break
        }
        default {
            Write-Host "Unknown choice." -ForegroundColor Yellow
        }
    }
}
