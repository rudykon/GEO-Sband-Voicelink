[CmdletBinding()]
param([switch]$CreateArchive)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$logDir = Join-Path $projectRoot 'artifacts/logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$auditPath = Join-Path $logDir 'repository_preflight_latest.json'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required for the upload file inventory.' }

# Use Git's actual ignore semantics without initializing the project itself.
if (Test-Path -LiteralPath (Join-Path $projectRoot '.git')) {
    $gitArgs = @('-C', $projectRoot)
} else {
    $inventoryRoot = Join-Path $projectRoot 'artifacts/debug/repository_inventory'
    New-Item -ItemType Directory -Path $inventoryRoot -Force | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $inventoryRoot '.git'))) {
        & git init --quiet $inventoryRoot
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the temporary inventory repository.' }
    }
    $gitArgs = @('--git-dir', (Join-Path $inventoryRoot '.git'), '--work-tree', $projectRoot)
}
$paths = @(& git @gitArgs -c core.quotepath=false -c core.excludesFile=NUL ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Git upload inventory failed.' }
$paths = @($paths | Sort-Object -Unique)
$pathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($path in $paths) { [void]$pathSet.Add($path.Replace('\','/')) }
$findings = [Collections.Generic.List[object]]::new()
$files = [Collections.Generic.List[object]]::new()
$ignoredTracked = @(& git @gitArgs -c core.quotepath=false -c core.excludesFile=NUL ls-files --cached --ignored --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect tracked files excluded by ignore rules.' }
foreach ($ignoredPath in $ignoredTracked) {
    $findings.Add(@{file=$ignoredPath; reason='Already tracked but excluded by current ignore rules; remove from the Git index before export'})
}
$requiredPaths = @('README.md','.gitignore','.gitattributes','code/matlab/run_step1_all.m',
    'code/matlab/+step1/defaultPaths.m',
    'code/matlab/+step1/+modules/execute.m','code/matlab/tests/run_step1_design_tests.m',
    'config/step1_macro_chain.json','config/examples/rf_device_comparison.json',
    'config/examples/stress_comparison.json','scripts/run_step1_matlab.ps1',
    'scripts/helpers/BoundedProcess.cs','docs/module_development.md')
foreach ($requiredPath in $requiredPaths) {
    if (-not $pathSet.Contains($requiredPath)) { $findings.Add(@{file=$requiredPath; reason='Required source-bundle file is missing or ignored'}) }
}
$rootPrefix = $projectRoot.TrimEnd('\') + '\'
$textExtensions = @('.m','.md','.json','.ps1','.cs','.yml','.yaml','.toml','.txt','.py','.ini','.config','.key','')
foreach ($path in $paths) {
    $normalized = $path.Replace('\','/')
    $absolute = [IO.Path]::GetFullPath((Join-Path $projectRoot $path))
    if (-not $absolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Inventory path escaped the project.' }
    if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) {
        $findings.Add(@{file=$normalized; reason='Missing file or unexpected nested repository/submodule'})
        continue
    }
    $item = Get-Item -LiteralPath $absolute
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $findings.Add(@{file=$normalized; reason='Linked files must not be included in the upload'})
        continue
    }
    if ($normalized -match '(^|/)(\.local|\.tmp|\.venv|\.git|slprj|__pycache__)(/|$)' -or
        $normalized -match '(^|/)(github_token\.json|id_(rsa|dsa|ecdsa|ed25519))$|\.(pem|p12|pfx|key|slxc|mexw64|asv)$' -or
        ($normalized -match '(^|/)\.env(\..*)?$' -and $item.Name -ne '.env.example') -or
        ($normalized -match '^(artifacts|archive)/' -and $normalized -ne 'artifacts/README.md')) {
        $findings.Add(@{file=$normalized; reason='File is outside the current source bundle or contains local/generated content'})
    }
    if ($item.Length -gt 20MB) { $findings.Add(@{file=$normalized; reason='Exceeds this repository source-bundle limit of 20 MiB per file'}) }
    if ($item.Extension.ToLowerInvariant() -in $textExtensions) {
        $content = [IO.File]::ReadAllText($absolute)
        # Findings contain filenames/reasons only, never matched credential text.
        if ($content -match 'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|-----BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}') {
            $findings.Add(@{file=$normalized; reason='Potential credential pattern; inspect locally before publication'})
        }
        if ($item.Extension -eq '.md') {
            $inlineLinks = @([regex]::Matches($content,'\]\(([^)]+)\)'))
            $referenceLinks = @([regex]::Matches($content,'(?m)^\s{0,3}\[[^\]]+\]:\s*(\S+)'))
            foreach ($match in ($inlineLinks + $referenceLinks)) {
                $target = $match.Groups[1].Value.Trim('<','>')
                if ($target -match '^(https?://|mailto:|#)') { continue }
                $target = [Uri]::UnescapeDataString(($target -split '#',2)[0])
                if (-not $target) { continue }
                $linkAbsolute = [IO.Path]::GetFullPath((Join-Path $item.DirectoryName $target))
                if (-not $linkAbsolute.StartsWith($rootPrefix,[StringComparison]::OrdinalIgnoreCase)) {
                    $findings.Add(@{file=$normalized; reason='Markdown link points outside the source bundle'})
                } else {
                    $linkRelative = $linkAbsolute.Substring($rootPrefix.Length).Replace('\','/')
                    if (-not $pathSet.Contains($linkRelative)) {
                        $findings.Add(@{file=$normalized; reason=('Markdown target is not included: ' + $linkRelative)})
                    }
                }
            }
        }
    }
    $files.Add(@{path=$normalized; bytes=$item.Length; sha256=(Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash.ToLowerInvariant()})
}
$totalBytes = [long]0
foreach ($entry in $files) { $totalBytes += [long]$entry.bytes }
$status = if ($findings.Count -gt 0) { 'failed' } elseif ($CreateArchive) { 'exporting' } else { 'passed' }
$audit = [ordered]@{schema_version='step1-repository-preflight-v1'; status=$status; file_count=$files.Count; total_bytes=$totalBytes; findings=@($findings.ToArray()); files=@($files.ToArray()); archive=$null}
$audit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8
if ($findings.Count -gt 0) {
    $findings | Format-Table file,reason -AutoSize | Out-Host
    throw "Repository preflight failed with $($findings.Count) finding(s). See artifacts/logs/repository_preflight_latest.json."
}
if ($CreateArchive) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $distDir = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    $archiveName = 'step1-macro-chain-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6) + '.zip'
    $archivePath = Join-Path $distDir $archiveName
    $pendingPath = $archivePath + '.partial'
    try {
        $stream = [IO.File]::Open($pendingPath,[IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $files) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $projectRoot $entry.path),$entry.path,[IO.Compression.CompressionLevel]::Optimal)
            }
        } finally { $zip.Dispose(); $stream.Dispose() }
        $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($entry in $files) { $expected.Add($entry.path,$entry.sha256) }
        $verification = [IO.Compression.ZipFile]::OpenRead($pendingPath)
        try {
            if ($verification.Entries.Count -ne $files.Count) { throw 'Archive file count does not match the inspected inventory.' }
            foreach ($entry in $verification.Entries) {
                if (-not $expected.ContainsKey($entry.FullName)) { throw 'Unexpected or duplicate archive entry.' }
                $entryStream = $entry.Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $digest = -join ($sha.ComputeHash($entryStream) | ForEach-Object { $_.ToString('x2') }) }
                finally { $sha.Dispose(); $entryStream.Dispose() }
                if ($digest -ne $expected[$entry.FullName]) { throw 'A source file changed while exporting; rerun the preflight.' }
                [void]$expected.Remove($entry.FullName)
            }
        } finally { $verification.Dispose() }
        Move-Item -LiteralPath $pendingPath -Destination $archivePath
        $audit.archive = 'dist/' + $archiveName
        $audit.status = 'passed'
        $audit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8
        Write-Host "Source archive: $archivePath"
    } catch {
        $audit.status = 'failed'
        $audit.findings = @(@{file='dist/'; reason='Archive export or content verification failed; no final archive was approved'})
        $audit | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $auditPath -Encoding UTF8
        throw
    }
}
Write-Host ("Repository preflight passed: {0} files, {1:N2} MiB. No upload was performed." -f $files.Count,($totalBytes / 1MB))
