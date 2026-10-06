param([string]$GodotPath = $env:GODOT_PATH)

$ErrorActionPreference = 'Stop'
if (-not $GodotPath -or -not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
	throw 'Pass -GodotPath with the Godot 4.5 executable path, or set GODOT_PATH.'
}
$projectPath = Split-Path -Parent $PSScriptRoot
$logDirectory = Join-Path $projectPath '.godot'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$importProcess = Start-Process -FilePath $GodotPath -WindowStyle Hidden -WorkingDirectory $projectPath -ArgumentList @('--headless', '--editor', '--import', '--quit', '--path', ('"{0}"' -f $projectPath), '--log-file', ('"{0}"' -f (Join-Path $logDirectory 'import-test.log'))) -RedirectStandardOutput (Join-Path $logDirectory 'import-stdout.log') -RedirectStandardError (Join-Path $logDirectory 'import-stderr.log') -PassThru -Wait
if ($importProcess.ExitCode -ne 0) {
	Get-Content -LiteralPath (Join-Path $logDirectory 'import-stderr.log') | Write-Output
	throw 'Godot asset import failed.'
}
$gameplayProcess = Start-Process -FilePath $GodotPath -WindowStyle Hidden -WorkingDirectory $projectPath -ArgumentList @('--headless', '--path', ('"{0}"' -f $projectPath), '--log-file', ('"{0}"' -f (Join-Path $logDirectory 'gameplay-test.log')), '--fixed-fps', '60', '--script', 'tests/gameplay_test.gd', '--', '--keyboard') -RedirectStandardOutput (Join-Path $logDirectory 'gameplay-stdout.log') -RedirectStandardError (Join-Path $logDirectory 'gameplay-stderr.log') -PassThru -Wait
$gameplayExitCode = $gameplayProcess.ExitCode
$gameplayOutput = Get-Content -LiteralPath (Join-Path $logDirectory 'gameplay-stdout.log')
$gameplayOutput | Write-Output
Get-Content -LiteralPath (Join-Path $logDirectory 'gameplay-stderr.log') | Write-Output
$gameplayResult = $gameplayOutput | Where-Object { $_.ToString().StartsWith('DINO_GAMEPLAY_RESULT ') } | Select-Object -Last 1
if ($gameplayExitCode -ne 0 -or -not $gameplayResult -or (($gameplayResult.ToString().Substring(21) | ConvertFrom-Json).failures.Count -ne 0)) {
	throw 'Dino gameplay verification failed.'
}
$transportProcess = Start-Process -FilePath $GodotPath -WindowStyle Hidden -WorkingDirectory $projectPath -ArgumentList @('--headless', '--path', ('"{0}"' -f $projectPath), '--log-file', ('"{0}"' -f (Join-Path $logDirectory 'transport-test.log')), '--script', 'tests/controller_transport_test.gd', '--', '--controller-url=http://127.0.0.1:19701') -RedirectStandardOutput (Join-Path $logDirectory 'transport-stdout.log') -RedirectStandardError (Join-Path $logDirectory 'transport-stderr.log') -PassThru -Wait
$transportExitCode = $transportProcess.ExitCode
$transportOutput = Get-Content -LiteralPath (Join-Path $logDirectory 'transport-stdout.log')
$transportOutput | Write-Output
Get-Content -LiteralPath (Join-Path $logDirectory 'transport-stderr.log') | Write-Output
$transportResult = $transportOutput | Where-Object { $_.ToString().StartsWith('DINO_TRANSPORT_RESULT ') } | Select-Object -Last 1
if ($transportExitCode -ne 0 -or -not $transportResult -or (($transportResult.ToString().Substring(22) | ConvertFrom-Json).failures.Count -ne 0)) {
	throw 'Dino controller transport verification failed.'
}
