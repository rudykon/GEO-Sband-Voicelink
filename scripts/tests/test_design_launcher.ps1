[CmdletBinding()]
param([string]$OutputPath = '')
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$testId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$fixtureRoot = Join-Path $projectRoot ('artifacts/logs/launcher-fixtures-' + $testId)
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $fixtureRoot 'test_results.json' }
$fakeExe = Join-Path $fixtureRoot 'fake-matlab.exe'
$fixtureSource = Join-Path $PSScriptRoot 'fixtures/FakeMatlab.cs'
$windowsPowerShell = (Get-Command powershell.exe).Source
# .NET Framework produces a directly runnable Windows fixture executable.
$compileCode = "Add-Type -Path '" + $fixtureSource.Replace("'", "''") + "' -OutputAssembly '" + $fakeExe.Replace("'", "''") + "' -OutputType ConsoleApplication"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($compileCode))
& $windowsPowerShell -NoProfile -NonInteractive -EncodedCommand $encoded
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeExe)) { throw 'Could not compile the fake MATLAB fixture.' }
. (Join-Path $projectRoot 'scripts/helpers/Invoke-BoundedProcess.ps1')
Initialize-Step1BoundedProcess
$tests = [Collections.Generic.List[object]]::new()
try {
    foreach ($mode in @('completed', 'missing_output', 'incomplete', 'wrong_run', 'nonzero', 'simulink_unicode', 'simulink_missing_model', 'comparison', 'comparison_missing', 'quick_alias')) {
        $runId = 'launcher-fixture-' + $testId + '-' + $mode
        $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $projectRoot 'scripts/run_step1_matlab.ps1'),
            '-MatlabExe', $fakeExe, '-RunId', $runId, '-MaxRuntimeSeconds', '30')
        if ($mode.StartsWith('simulink_')) { $arguments += '-UseSimulink' }
        if ($mode.StartsWith('comparison')) { $arguments += '-CompareBaseline' }
        if ($mode -eq 'quick_alias') { $arguments += @('-Profile', 'quick') }
        $observed = Invoke-Step1BoundedProcess -FilePath $windowsPowerShell -ArgumentList $arguments -WorkingDirectory $projectRoot `
            -MaxRuntimeSeconds 40 -MemoryLimitBytes 1GB -EnvironmentOverrides @{ STEP1_FAKE_MATLAB_MODE = $mode }
        $resourcePath = Join-Path $projectRoot ('artifacts/logs/design_resources_' + $runId + '.json')
        $resource = Get-Content -LiteralPath $resourcePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $runStatus = Get-Content -LiteralPath (Join-Path $resource.run_directory 'run_status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $expectedCode = if ($mode -in @('completed','simulink_unicode','comparison','quick_alias')) { 0 } elseif ($mode -eq 'nonzero') { 7 } else { 1 }
        if ($observed.ExitCode -ne $expectedCode) { throw "$mode exit $($observed.ExitCode), expected $expectedCode; resource error: $($resource.error)" }
        if ($expectedCode -eq 0) {
            if ($resource.status -ne 'completed' -or $resource.output_validation -ne 'passed' -or $runStatus.status -ne 'completed') { throw 'Valid output was not accepted.' }
        }
        elseif ($resource.status -ne 'failed' -or $runStatus.status -ne 'failed') { throw "$mode incorrectly reported completed." }
        if ($mode.StartsWith('simulink_')) {
            $modelName = [string][char]0x5929 + [char]0x901A + [char]0x6A21 + [char]0x578B + '.slx'
            $expectedModelPath = Join-Path $resource.run_directory ('staging/simulink/' + $modelName)
            if ($runStatus.simulink.model_path -cne $expectedModelPath) { throw "$mode corrupted the UTF-8 model path during validation or failure persistence." }
            $statusBytes = [IO.File]::ReadAllBytes((Join-Path $resource.run_directory 'run_status.json'))
            if ($statusBytes[0] -ne 123) { throw "$mode fixture did not use UTF-8 without BOM." }
        }
        if ($resource.wall_seconds -ge 30) { throw "$mode exceeded the whole-launcher budget." }
        if ($mode -eq 'quick_alias' -and ($resource.profile -ne 'design' -or $resource.requested_profile -ne 'quick' -or $resource.limit_status -ne 'within_limits')) { throw 'Quick did not use the bounded design runtime.' }
        $tests.Add([pscustomobject]@{ name = $mode; passed = $true; exit_code = $observed.ExitCode; external_wall_seconds = $observed.WallSeconds; resource_status = $resourcePath })
        Write-Host "PASS launcher_$mode"
    }
    $unsupportedId = 'launcher-fixture-' + $testId + '-unsupported-profile'
    $unsupported = Invoke-Step1BoundedProcess -FilePath $windowsPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-File',(Join-Path $projectRoot 'scripts/run_step1_matlab.ps1'),'-Profile','full','-MatlabExe',$fakeExe,'-RunId',$unsupportedId) `
        -WorkingDirectory $projectRoot -MaxRuntimeSeconds 10 -MemoryLimitBytes 1GB
    if ($unsupported.ExitCode -eq 0 -or (Test-Path -LiteralPath (Join-Path $projectRoot ('artifacts/results/step1_design/runs/' + $unsupportedId))) -or
        (Test-Path -LiteralPath (Join-Path $projectRoot ('artifacts/logs/design_resources_' + $unsupportedId + '.json')))) { throw 'Unsupported profile did not fail before launching or creating run artifacts.' }
    $tests.Add([pscustomobject]@{ name='unsupported_profile_before_launch'; passed=$true; exit_code=$unsupported.ExitCode; external_wall_seconds=$unsupported.WallSeconds })
    Write-Host 'PASS launcher_unsupported_profile_before_launch'
    $report = [ordered]@{ schema_version = 'step1-design-launcher-tests-v1'; status = 'passed'; passed = $tests.Count; failed = 0; tests = $tests.ToArray() }
}
catch {
    $report = [ordered]@{ schema_version = 'step1-design-launcher-tests-v1'; status = 'failed'; passed = $tests.Count; failed = 1; tests = $tests.ToArray(); error = $_.Exception.Message }
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
Write-Host "Report: $OutputPath"
if ($report.status -ne 'passed') { throw $report.error }
