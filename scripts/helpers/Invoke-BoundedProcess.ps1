function Initialize-Step1BoundedProcess {
    if (-not ('Step1.Resources.BoundedProcess' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'BoundedProcess.cs')
    }
}

function Invoke-Step1BoundedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][ValidateRange(0.05, 600)][double]$MaxRuntimeSeconds,
        [Parameter(Mandatory)][ValidateRange(1048576, 8589934592)][uint64]$MemoryLimitBytes,
        [Parameter()][hashtable]$EnvironmentOverrides = @{}
    )
    Initialize-Step1BoundedProcess
    # Build a private Unicode environment block for CreateProcess. The
    # launcher's process/user/machine environment is never changed.
    [string[]]$names = @($EnvironmentOverrides.Keys)
    [string[]]$values = @($names | ForEach-Object { [string]$EnvironmentOverrides[$_] })
    return [Step1.Resources.BoundedProcess]::Run(
        [IO.Path]::GetFullPath($FilePath), $ArgumentList,
        [IO.Path]::GetFullPath($WorkingDirectory), $MaxRuntimeSeconds, $MemoryLimitBytes, $names, $values)
}
