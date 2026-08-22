$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Icacls {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $IcaclsArgs
    )

    Write-Host ("icacls.exe " + ($IcaclsArgs -join " "))
    & "$env:SystemRoot\System32\icacls.exe" @IcaclsArgs
    if ($LASTEXITCODE -ne 0) {
        throw "icacls exited with code $LASTEXITCODE"
    }
}

function Get-OwnerSid {
    param(
        [Parameter(Mandatory = $true)]
        [string] $LiteralPath
    )

    $owner = (Get-Acl -LiteralPath $LiteralPath).Owner
    $account = [System.Security.Principal.NTAccount]::new($owner)
    return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$targetOwnerName = $currentIdentity.Name
$targetOwnerSid = $currentIdentity.User.Value
$targetOwnerArg = "*$targetOwnerSid"
$administratorsSid = "S-1-5-32-544"
$administratorsArg = "*$administratorsSid"

$testRoot = Join-Path $env:RUNNER_TEMP ("taskcluster-icacls-reparse-" + [guid]::NewGuid().ToString("N"))
$cacheRoot = Join-Path $testRoot "cache"
$outsideRoot = Join-Path $testRoot "outside"
$outsideFile = Join-Path $outsideRoot "must-not-be-reowned.txt"
$junction = Join-Path $cacheRoot "outside-junction"
$resultPath = Join-Path $env:GITHUB_WORKSPACE "icacls-reparse-result.json"

New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
Set-Content -LiteralPath $outsideFile -Value "temporary host-side sentinel"
New-Item -ItemType Junction -Path $junction -Target $outsideRoot | Out-Null

try {
    # Establish a distinct baseline owner for both the target directory and file.
    # Setting the cache first is intentional: if recursion follows the junction,
    # the subsequent outside reset still makes the baseline deterministic.
    Invoke-Icacls -IcaclsArgs @($cacheRoot, "/setowner", $administratorsArg, "/T")
    Invoke-Icacls -IcaclsArgs @($outsideRoot, "/setowner", $administratorsArg, "/T")

    $baselineDirectoryOwner = Get-OwnerSid -LiteralPath $outsideRoot
    $baselineFileOwner = Get-OwnerSid -LiteralPath $outsideFile
    if ($baselineDirectoryOwner -ne $administratorsSid -or $baselineFileOwner -ne $administratorsSid) {
        throw "Could not establish the Administrators ownership baseline"
    }

    # Negative control: without /T, changing the cache root must not reach the
    # junction target.
    Invoke-Icacls -IcaclsArgs @($cacheRoot, "/setowner", $targetOwnerArg)
    $afterNonRecursiveDirectoryOwner = Get-OwnerSid -LiteralPath $outsideRoot
    $afterNonRecursiveFileOwner = Get-OwnerSid -LiteralPath $outsideFile
    $nonRecursiveStayedContained =
        $afterNonRecursiveDirectoryOwner -eq $administratorsSid -and
        $afterNonRecursiveFileOwner -eq $administratorsSid

    # Exact affected command shape from makeFileOrDirReadWritableForUser.
    Invoke-Icacls -IcaclsArgs @($cacheRoot, "/setowner", $targetOwnerArg, "/T")
    $afterRecursiveDirectoryOwner = Get-OwnerSid -LiteralPath $outsideRoot
    $afterRecursiveFileOwner = Get-OwnerSid -LiteralPath $outsideFile
    $recursiveCrossedBoundary =
        $afterRecursiveDirectoryOwner -eq $targetOwnerSid -or
        $afterRecursiveFileOwner -eq $targetOwnerSid

    # Proposed no-follow control. Reset the baseline, then repeat with /L.
    Invoke-Icacls -IcaclsArgs @($cacheRoot, "/setowner", $administratorsArg, "/T")
    Invoke-Icacls -IcaclsArgs @($outsideRoot, "/setowner", $administratorsArg, "/T")
    Invoke-Icacls -IcaclsArgs @($cacheRoot, "/setowner", $targetOwnerArg, "/L", "/T")
    $afterNoFollowDirectoryOwner = Get-OwnerSid -LiteralPath $outsideRoot
    $afterNoFollowFileOwner = Get-OwnerSid -LiteralPath $outsideFile
    $slashLStayedContained =
        $afterNoFollowDirectoryOwner -eq $administratorsSid -and
        $afterNoFollowFileOwner -eq $administratorsSid

    $result = [ordered]@{
        osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
        osVersion = [System.Environment]::OSVersion.VersionString
        imageVersion = $env:ImageVersion
        currentIdentity = $targetOwnerName
        currentIdentitySid = $targetOwnerSid
        junctionPath = $junction
        junctionTarget = $outsideRoot
        baselineDirectoryOwnerSid = $baselineDirectoryOwner
        baselineFileOwnerSid = $baselineFileOwner
        afterNonRecursiveDirectoryOwnerSid = $afterNonRecursiveDirectoryOwner
        afterNonRecursiveFileOwnerSid = $afterNonRecursiveFileOwner
        afterRecursiveDirectoryOwnerSid = $afterRecursiveDirectoryOwner
        afterRecursiveFileOwnerSid = $afterRecursiveFileOwner
        afterNoFollowDirectoryOwnerSid = $afterNoFollowDirectoryOwner
        afterNoFollowFileOwnerSid = $afterNoFollowFileOwner
        nonRecursiveStayedContained = $nonRecursiveStayedContained
        recursiveCrossedBoundary = $recursiveCrossedBoundary
        slashLStayedContained = $slashLStayedContained
    }

    $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath
    $result | Format-List | Out-String | Write-Host

    if ($env:GITHUB_STEP_SUMMARY) {
        @"
## Taskcluster icacls reparse-point validation

- Runner: $($result.osCaption) ($($result.osVersion))
- Non-recursive control stayed contained: $nonRecursiveStayedContained
- Recursive /T crossed the junction boundary: $recursiveCrossedBoundary
- /L /T stayed contained: $slashLStayedContained
- Outside directory owner after /T: $afterRecursiveDirectoryOwner
- Outside file owner after /T: $afterRecursiveFileOwner
"@ | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
    }

    if (-not $nonRecursiveStayedContained) {
        throw "Negative control failed: a non-recursive operation changed the outside owner"
    }
    if (-not $recursiveCrossedBoundary) {
        throw "NOT REPRODUCED: icacls /setowner /T did not change the junction target ownership"
    }
    if (-not $slashLStayedContained) {
        throw "The proposed /L control did not keep ownership changes inside the cache"
    }

    Write-Host "REPRODUCED: recursive icacls ownership transfer crossed the cache junction boundary."
}
finally {
    if (Test-Path -LiteralPath $junction) {
        & "$env:SystemRoot\System32\cmd.exe" /d /c "rmdir `"$junction`""
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not remove temporary junction $junction"
        }
    }
    if (Test-Path -LiteralPath $cacheRoot) {
        Remove-Item -LiteralPath $cacheRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $outsideRoot) {
        Remove-Item -LiteralPath $outsideRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
