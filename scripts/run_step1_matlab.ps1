[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet("design", "quick", "full")]
    [string]$Profile = "design",

    [Parameter()]
    [string]$ConfigPath = "",

    [Parameter()]
    [string]$MatlabExe = "",

    [Parameter()]
    [string]$RunId = "",

    [Parameter()]
    [switch]$SkipPlots,

    [Parameter()]
    [switch]$SkipReport,

    [Parameter()]
    [switch]$UseSimulink,

    [Parameter()]
    [switch]$CompareBaseline,

    [Parameter()]
    [ValidateRange(1, 600)]
    [double]$MaxRuntimeSeconds = 600,

    [Parameter()]
    [ValidateRange(0.01, 8)]
    [double]$MemoryLimitGB = 8
)

$launcherTimer = [Diagnostics.Stopwatch]::StartNew()
$launcherStartedAt = [DateTime]::UtcNow.ToString('o')
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$projectRoot = [IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
$requestedProfile = $Profile
if ($Profile -eq 'full') {
    throw 'step1:RetiredProfile: Supported simulation profile: design. Use Profile=design for the bounded modular workflow.'
}
if ($Profile -eq 'quick') { $Profile = 'design'; Write-Host 'Profile quick is a compatibility alias for the bounded design workflow.' }

function Test-AsciiPath {
    param([Parameter(Mandatory)][string]$Value)
    foreach ($character in $Value.ToCharArray()) {
        if ([int]$character -gt 127) { return $false }
    }
    return $true
}

function Get-PathDigestPrefix {
    param([Parameter(Mandatory)][string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        $digest = $sha.ComputeHash($bytes)
        return (-join ($digest | ForEach-Object { $_.ToString("x2") })).Substring(0, 12)
    }
    finally {
        $sha.Dispose()
    }
}

function Resolve-MatlabExecutable {
    param([string]$Requested)
    $candidates = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { $candidates.Add($Requested) }
    if (-not [string]::IsNullOrWhiteSpace($env:MATLAB_EXE)) { $candidates.Add($env:MATLAB_EXE) }
    foreach ($commandName in @("matlab.exe", "matlab")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { $candidates.Add($command.Source) }
    }
    $candidates.Add("D:\Program Files\matlab\bin\matlab.exe")
    $candidates.Add("D:\Program Files\matlab2026\bin\matlab.exe")
    $candidates.Add("D:\matlab\bin\matlab.exe")

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw "MATLAB executable not found. Pass -MatlabExe or set MATLAB_EXE."
}

function Get-AsciiExecutionRoot {
    param([Parameter(Mandatory)][string]$CanonicalRoot)
    if (Test-AsciiPath $CanonicalRoot) { return $CanonicalRoot }

    if (-not [string]::IsNullOrWhiteSpace($env:STEP1_MATLAB_ALIAS_ROOT)) {
        $aliasRoot = [IO.Path]::GetFullPath($env:STEP1_MATLAB_ALIAS_ROOT)
        if (-not (Test-AsciiPath $aliasRoot)) {
            throw "STEP1_MATLAB_ALIAS_ROOT must be ASCII-only: $aliasRoot"
        }
    }
    else {
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not (Test-AsciiPath $tempRoot)) {
            throw "The temporary directory is not ASCII-only. Set STEP1_MATLAB_ALIAS_ROOT."
        }
        $suffix = Get-PathDigestPrefix $CanonicalRoot
        $aliasRoot = Join-Path $tempRoot "step1_link_matlab_$suffix"
    }

    if (-not (Test-Path -LiteralPath $aliasRoot)) {
        $output = & cmd.exe /d /c "mklink /J `"$aliasRoot`" `"$CanonicalRoot`"" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create MATLAB ASCII junction $aliasRoot`: $output"
        }
    }

    $item = Get-Item -LiteralPath $aliasRoot -Force
    if ($item.LinkType -ne "Junction") {
        throw "Existing MATLAB alias is not a junction: $aliasRoot"
    }
    $target = [IO.Path]::GetFullPath([string](@($item.Target)[0]))
    if (-not $target.Equals($CanonicalRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "MATLAB alias targets '$target', expected '$CanonicalRoot'."
    }
    return $aliasRoot
}

function Convert-ToExecutionPath {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$CanonicalRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $full = if ([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $CanonicalRoot $Path))
    }
    $rootPrefix = $CanonicalRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path $ExecutionRoot $full.Substring($rootPrefix.Length)
    }
    if (-not (Test-AsciiPath $full)) {
        throw "External ConfigPath must be ASCII-only or live under the project root: $full"
    }
    return $full
}

function Quote-MatlabString {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Write-ResourceJson {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Get-ObservedHardware {
    $hardware = [ordered]@{ host_total_ram_bytes = $null; gpu_names = @(); status = 'unavailable'; detail = '' }
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 2 -ErrorAction Stop
        $hardware.host_total_ram_bytes = [uint64]$system.TotalPhysicalMemory
        $hardware.status = 'ram_available'
        try {
            $hardware.gpu_names = @(Get-CimInstance -ClassName Win32_VideoController -OperationTimeoutSec 2 -ErrorAction Stop | ForEach-Object { $_.Name })
            $hardware.status = 'available'
        }
        catch { $hardware.detail = 'GPU metadata unavailable: ' + $_.Exception.Message }
    }
    catch { $hardware.detail = $_.Exception.Message }
    return $hardware
}

function Test-DesignOutputs {
    param([string]$Directory, [string]$ExpectedRunId)
    $statusPath = Join-Path $Directory 'run_status.json'
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { throw "Missing run status: $statusPath" }
    $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($status.status -ne 'completed' -or $status.run_id -ne $ExpectedRunId -or $status.profile -ne 'design') {
        throw "This run did not complete: status=$($status.status), run_id=$($status.run_id), profile=$($status.profile)"
    }
    $required = @('staging/results/summary.csv', 'staging/results/link_budget.csv', 'staging/results/sensitivity.csv',
        'staging/results/trace.csv', 'staging/results/assumptions.json', 'staging/results/end_to_end_summary.csv', 'staging/results/chain_stages.csv',
        'staging/results/module_manifest.json')
    if ($CompareBaseline) { $required += @('staging/results/module_comparison.csv', 'staging/results/baseline_end_to_end_summary.csv') }
    if (-not $SkipPlots) { $required += 'staging/figures/design_overview.png' }
    if (-not $SkipReport) { $required += 'staging/report/design_report.md' }
    foreach ($relative in $required) {
        $path = Join-Path $Directory $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -eq 0) {
            throw "Missing or empty required output: $path"
        }
    }
    if ($UseSimulink) {
        if ($status.simulink.status -ne 'completed') { throw "Requested Simulink check did not complete: $($status.simulink.status)" }
        if ([string]::IsNullOrWhiteSpace($status.simulink.model_path) -or -not (Test-Path -LiteralPath $status.simulink.model_path -PathType Leaf)) {
            throw "Requested Simulink model is missing: $($status.simulink.model_path)"
        }
        if (-not $status.simulink.all_configured_cases_covered -or $status.simulink.coverage_count -lt 1 -or
            @($status.simulink.coverage).Count -ne $status.simulink.coverage_count -or $status.simulink.decision_mismatches -ne 0) {
            throw 'Requested Simulink verification did not cover every configured scenario/rate without decision mismatches.'
        }
    }
    return $required
}

function Set-DesignLaunchFailure {
    param([string]$Directory, [string]$FailureStatus, [string]$Detail)
    $statusPath = Join-Path $Directory 'run_status.json'
    $status = $null
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        try { $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    if ($null -eq $status) { $status = [pscustomobject]@{ schema_version = 'step1-design-run-v1'; run_id = $RunId; profile = 'design'; authoritative = $false } }
    $status | Add-Member -NotePropertyName status -NotePropertyValue 'failed' -Force
    $status | Add-Member -NotePropertyName launcher_failure -NotePropertyValue ([ordered]@{ status = $FailureStatus; detail = $Detail }) -Force
    $status | Add-Member -NotePropertyName completed_at -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-ResourceJson $statusPath $status
    $latestPath = Join-Path (Split-Path -Parent (Split-Path -Parent $Directory)) 'latest_status.json'
    # Do not replace another concurrent run's latest status.
    if (Test-Path -LiteralPath $latestPath -PathType Leaf) {
        try {
            $latest = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($latest.run_id -eq $RunId) {
                $latest.status = 'failed'; $latest.updated_at = [DateTime]::UtcNow.ToString('o')
                Write-ResourceJson $latestPath $latest
            }
        } catch { Write-Warning "Could not update latest status: $($_.Exception.Message)" }
    }
}

$resource = $null
$runDirectory = ''
if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-design-' + [guid]::NewGuid().ToString('N').Substring(0, 8) }
$RunId = [regex]::Replace($RunId, '[^A-Za-z0-9_.-]', '-')
if ($RunId -eq '.' -or $RunId -eq '..') { throw 'RunId must contain a safe filename character.' }
$runDirectory = Join-Path $projectRoot ('artifacts/results/step1_design/runs/' + $RunId)
if (Test-Path -LiteralPath $runDirectory) { throw "Refusing to reuse an existing immutable run directory: $runDirectory" }
$resourcePath = Join-Path $projectRoot ('artifacts/logs/design_resources_' + $RunId + '.json')
$matlabLogPath = Join-Path $projectRoot ('artifacts/logs/design_matlab_' + $RunId + '.log')
$resource = [ordered]@{
    schema_version = 'step1-design-resources-v1'; run_id = $RunId; profile = 'design'; requested_profile = $requestedProfile; compare_baseline = [bool]$CompareBaseline; status = 'running'; limit_status = 'preparing'
    started_at = $launcherStartedAt; max_runtime_seconds = $MaxRuntimeSeconds; memory_limit_bytes = [uint64]($MemoryLimitGB * 1GB)
    required_gpu = $false; cpu_threads = 1; cpu_thread_scope = 'Configured MATLAB numerical compute/MKL/OMP parallelism; background threads may still exist'; parallel_pool = $false
    memory_metric = 'Windows Job Object aggregate private commit; hard allocation cap; working set sampled every 100 ms'
    process_scope = 'Only this suspended-created MATLAB process and all descendants, with kill-on-job-close'
    wall_time_scope = 'Launcher preflight, MATLAB cold startup, compute, Simulink if requested, plots/report, process exit and output validation'
    wall_seconds = 0.0; process_wall_seconds = 0.0; peak_private_bytes = 0; peak_working_set_bytes = 0
    process_count = 0; process_id = 0; exit_code = 1; output_validation = 'not_run'; required_outputs = @()
    run_directory = $runDirectory; matlab_log_path = $matlabLogPath; hardware = $null; error = ''
}
Write-ResourceJson $resourcePath $resource

$matlabExitCode = 1
$previousCanonicalRoot = $env:STEP1_CANONICAL_PROJECT_ROOT
try {
    . (Join-Path $scriptDir 'helpers/Invoke-BoundedProcess.ps1')
    Initialize-Step1BoundedProcess
    $resource.hardware = Get-ObservedHardware

    $resolvedMatlab = Resolve-MatlabExecutable $MatlabExe
    $executionRoot = Get-AsciiExecutionRoot $projectRoot
    $executionConfig = Convert-ToExecutionPath $ConfigPath $projectRoot $executionRoot
    $matlabDir = Join-Path $executionRoot "code\matlab"

    $profileLiteral = Quote-MatlabString $Profile
    $configLiteral = Quote-MatlabString $executionConfig
    $runIdLiteral = Quote-MatlabString $RunId
    $matlabDirLiteral = Quote-MatlabString $matlabDir
    $skipPlotsLiteral = if ($SkipPlots) { "true" } else { "false" }
    $skipReportLiteral = if ($SkipReport) { "true" } else { "false" }
    $useSimulinkLiteral = if ($UseSimulink) { "true" } else { "false" }
    $compareBaselineLiteral = if ($CompareBaseline) { "true" } else { "false" }

    $command = @"
try, cd($matlabDirLiteral); addpath($matlabDirLiteral); run_step1_all(Profile=$profileLiteral, ConfigPath=$configLiteral, SkipPlots=$skipPlotsLiteral, SkipReport=$skipReportLiteral, UseSimulink=$useSimulinkLiteral, CompareBaseline=$compareBaselineLiteral, RunId=$runIdLiteral); catch ME, disp(getReport(ME,'extended','hyperlinks','off')); exit(1); end; exit(0);
"@.Trim()

    $env:STEP1_CANONICAL_PROJECT_ROOT = $projectRoot
    Write-Host "MATLAB:   $resolvedMatlab"
    Write-Host "Project:  $projectRoot"
    if ($executionRoot -ne $projectRoot) { Write-Host "ASCII:    $executionRoot" }
    Write-Host "Profile:  $Profile"

    Push-Location -LiteralPath $executionRoot
    try {
        $matlabArguments = @("-wait", "-nodesktop", "-nosplash", "-noFigureWindows")
        $matlabArguments += "-singleCompThread"
        $executionLogPath = Convert-ToExecutionPath $matlabLogPath $projectRoot $executionRoot
        $matlabArguments += @('-logfile', $executionLogPath)

        $matlabArguments += @("-r", $command)
        # Reserve up to ten seconds for cleanup/status persistence. Short
        # fixture budgets retain 80% for the process after preflight.
        $reserveSeconds = [Math]::Min(10, $MaxRuntimeSeconds * 0.2)
        $remainingSeconds = $MaxRuntimeSeconds - $reserveSeconds - $launcherTimer.Elapsed.TotalSeconds
        if ($remainingSeconds -lt 0.05) { $resource.limit_status = 'timeout'; $matlabExitCode = 124; throw 'Runtime budget exhausted during launcher preflight.' }
        Write-Host "Budget:   $MaxRuntimeSeconds s launcher wall time; $MemoryLimitGB GiB aggregate private memory; CPU only"
        Write-Host "Log:      $matlabLogPath"
        $observed = Invoke-Step1BoundedProcess -FilePath $resolvedMatlab -ArgumentList $matlabArguments -WorkingDirectory $executionRoot `
            -MaxRuntimeSeconds $remainingSeconds -MemoryLimitBytes $resource.memory_limit_bytes `
            -EnvironmentOverrides @{ CUDA_VISIBLE_DEVICES = '-1'; OMP_NUM_THREADS = '1'; MKL_NUM_THREADS = '1'; STEP1_MATLAB_EXECUTION_ROOT = $executionRoot }
        $matlabExitCode = $observed.ExitCode
        $resource.limit_status = $observed.LimitStatus
        $resource.process_wall_seconds = $observed.WallSeconds
        $resource.peak_private_bytes = $observed.PeakPrivateBytes
        $resource.peak_working_set_bytes = $observed.PeakWorkingSetBytes
        $resource.process_count = $observed.TotalProcesses
        $resource.process_id = $observed.ProcessId
        $resource.error = $observed.Error
        if ($matlabExitCode -eq 0) {
            $resource.required_outputs = @(Test-DesignOutputs $runDirectory $RunId)
            $resource.output_validation = 'passed'
            if ($launcherTimer.Elapsed.TotalSeconds -gt $MaxRuntimeSeconds) {
                $resource.limit_status = 'timeout'; $matlabExitCode = 124; throw 'Runtime budget exceeded during output validation.'
            }
            $resource.status = 'completed'
        }
        else { throw "Bounded MATLAB run failed: $($resource.limit_status), exit code $matlabExitCode. $($resource.error)" }

    }
    finally {
        Pop-Location
    }
}
catch {

    if ($matlabExitCode -eq 0 -or $matlabExitCode -eq 1) { $matlabExitCode = 1 }
    $resource.status = 'failed'
    if ($resource.limit_status -eq 'within_limits') { $resource.limit_status = 'output_validation_failed'; $resource.output_validation = 'failed' }
    elseif ($resource.limit_status -eq 'preparing') { $resource.limit_status = 'preflight_failed' }
    $resource.error = $_.Exception.Message
    Set-DesignLaunchFailure $runDirectory $resource.limit_status $resource.error
}
finally {
    $env:STEP1_CANONICAL_PROJECT_ROOT = $previousCanonicalRoot
    if ($null -ne $resource) {
        $resource.exit_code = $matlabExitCode
        $resource.wall_seconds = $launcherTimer.Elapsed.TotalSeconds
        $resource.completed_at = [DateTime]::UtcNow.ToString('o')
        Write-ResourceJson $resourcePath $resource
        if (Test-Path -LiteralPath $runDirectory -PathType Container) { Write-ResourceJson (Join-Path $runDirectory 'resource_status.json') $resource }
        Write-Host "Resource: $resourcePath"
        Write-Host ("Observed: {0:N2} s; peak private {1:N3} GiB; peak working set {2:N3} GiB; {3}" -f $resource.wall_seconds, ($resource.peak_private_bytes / 1GB), ($resource.peak_working_set_bytes / 1GB), $resource.limit_status)
    }
}

if ($matlabExitCode -ne 0) {
    [Console]::Error.WriteLine("MATLAB Step 1 $Profile run failed with exit code $matlabExitCode.")
    exit $matlabExitCode
}
exit 0
