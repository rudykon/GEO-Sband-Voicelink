[CmdletBinding()]
param([string]$OutputPath = '')
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $projectRoot 'scripts/helpers/Invoke-BoundedProcess.ps1')
Initialize-Step1BoundedProcess
$executable = (Get-Command powershell.exe).Source
$fixtureRoot = Join-Path $projectRoot ('artifacts/logs/resource-fixtures-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $fixtureRoot 'test_results.json' }
$results = [Collections.Generic.List[object]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-Fixture([string]$Body, [double]$Seconds = 10, [uint64]$Memory = 536870912, [hashtable]$EnvironmentOverrides = @{}) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Body))
    Invoke-Step1BoundedProcess -FilePath $executable -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
        -WorkingDirectory $fixtureRoot -MaxRuntimeSeconds $Seconds -MemoryLimitBytes $Memory -EnvironmentOverrides $EnvironmentOverrides
}
function Record([string]$Name, [object]$Observed) {
    $results.Add([pscustomobject]@{ name = $Name; passed = $true; observed = $Observed })
    Write-Host "PASS $Name"
}

try {
    $success = Invoke-Fixture 'exit 0'
    Assert-True ($success.ExitCode -eq 0 -and $success.LimitStatus -eq 'within_limits') 'Success was not recognized.'
    Assert-True ($success.PeakPrivateBytes -gt 0 -and $success.PeakWorkingSetBytes -gt 0) 'Resource measurements were not captured.'
    Record 'success_and_memory_measurement' $success

    $failed = Invoke-Fixture 'exit 7'
    Assert-True ($failed.ExitCode -eq 7 -and $failed.LimitStatus -eq 'process_failed') 'Child exit code was not preserved.'
    Record 'nonzero_exit_preserved' $failed

    $timeout = Invoke-Fixture 'Start-Sleep -Seconds 15' 1.5
    Assert-True ($timeout.ExitCode -eq 124 -and $timeout.LimitStatus -eq 'timeout') 'Timeout was not enforced.'
    Assert-True ($timeout.WallSeconds -lt 3) 'Timeout termination exceeded its cleanup tolerance.'
    Assert-True ($null -eq (Get-Process -Id $timeout.ProcessId -ErrorAction SilentlyContinue)) 'Timed out parent survived.'
    Record 'wall_clock_timeout' $timeout

    $childBody = "Start-Sleep -Seconds 10; [IO.File]::WriteAllText('surviving-child.txt','bad')"
    $childEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childBody))
    $treeBody = @'
$child = Start-Process -FilePath (Get-Command powershell.exe).Source -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', 'CHILD_CODE') -PassThru
[IO.File]::WriteAllText('child_pid.txt', [string]$child.Id)
Start-Sleep -Seconds 15
'@.Replace('CHILD_CODE', $childEncoded)
    $tree = Invoke-Fixture $treeBody 3
    Assert-True ($tree.ExitCode -eq 124) 'Descendant fixture did not time out.'
    $childId = [int](Get-Content -LiteralPath (Join-Path $fixtureRoot 'child_pid.txt') -Raw -Encoding UTF8)
    Assert-True ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'An owned descendant survived job termination.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'surviving-child.txt'))) 'A terminated descendant continued running.'
    Assert-True ($tree.TotalProcesses -ge 2) 'The process tree was not counted.'
    Record 'timeout_kills_owned_descendants' $tree

    # Keep allocating committed pages so the aggregate job hard cap is hit.
    $memoryBody = '$buffers = [Collections.Generic.List[byte[]]]::new(); for ($i = 0; $i -lt 80; $i++) { $b = [byte[]]::new(8MB); for ($j = 0; $j -lt $b.Length; $j += 4096) { $b[$j] = 1 }; $buffers.Add($b); Start-Sleep -Milliseconds 20 }; Start-Sleep -Seconds 10'
    $memory = Invoke-Fixture $memoryBody 10 (128MB)
    Assert-True ($memory.ExitCode -eq 125 -and $memory.LimitStatus -eq 'memory_limit_exceeded') 'Memory allocation limit was not enforced.'
    Assert-True ($memory.WallSeconds -lt 5) 'The memory-limit violation was not terminated promptly.'
    Assert-True ($null -eq (Get-Process -Id $memory.ProcessId -ErrorAction SilentlyContinue)) 'Memory-limited parent survived.'
    Record 'aggregate_memory_hard_limit' $memory

    $beforeCuda = [Environment]::GetEnvironmentVariable('CUDA_VISIBLE_DEVICES', 'Process')
    $envResult = Invoke-Fixture "[IO.File]::WriteAllText('env.txt', [string]`$env:CUDA_VISIBLE_DEVICES)" 10 536870912 @{ CUDA_VISIBLE_DEVICES = '-1' }
    Assert-True ($envResult.ExitCode -eq 0) 'Environment fixture did not complete.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $fixtureRoot 'env.txt') -Raw -Encoding UTF8) -eq '-1') 'Child did not receive CPU-only environment.'
    Assert-True ([Environment]::GetEnvironmentVariable('CUDA_VISIBLE_DEVICES', 'Process') -eq $beforeCuda) 'Parent environment was not restored.'
    Record 'child_environment_isolation' $envResult

    $argumentFixture = Join-Path $fixtureRoot 'argument echo.ps1'
    [IO.File]::WriteAllText($argumentFixture, 'param([string]$Value) [IO.File]::WriteAllText("argument.txt", $Value)')
    $argument = 'space path\trailing\'
    $quoted = Invoke-Step1BoundedProcess -FilePath $executable -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $argumentFixture, $argument) `
        -WorkingDirectory $fixtureRoot -MaxRuntimeSeconds 10 -MemoryLimitBytes 536870912
    Assert-True ($quoted.ExitCode -eq 0) 'Quoted-argument fixture failed.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $fixtureRoot 'argument.txt') -Raw -Encoding UTF8) -ceq $argument) 'Windows command-line quoting changed a trailing slash or whitespace.'
    Record 'windows_argument_quoting' $quoted

    $unrelated = Start-Process -FilePath $executable -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 15') -PassThru
    try {
        $isolated = Invoke-Fixture 'Start-Sleep -Seconds 15' 1
        Assert-True (-not $unrelated.HasExited) 'Job termination affected an unrelated process.'
        Record 'unrelated_process_survives' $isolated
    }
    finally { if (-not $unrelated.HasExited) { $unrelated.Kill(); $unrelated.WaitForExit() }; $unrelated.Dispose() }

    $report = [ordered]@{ schema_version = 'step1-resource-watchdog-tests-v1'; status = 'passed'; passed = $results.Count; failed = 0; tests = $results.ToArray(); fixture_root = $fixtureRoot }
}
catch {
    $report = [ordered]@{ schema_version = 'step1-resource-watchdog-tests-v1'; status = 'failed'; passed = $results.Count; failed = 1; tests = $results.ToArray(); error = $_.Exception.Message; fixture_root = $fixtureRoot }
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($report | ConvertTo-Json -Depth 15), [Text.UTF8Encoding]::new($false))
Write-Host "Report: $OutputPath"
if ($report.status -ne 'passed') { throw $report.error }
