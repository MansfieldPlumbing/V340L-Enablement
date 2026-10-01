<#
.SYNOPSIS
    Prepares, but never installs, the AMD Software: PRO Edition 22.Q4 V340L driver package.

.DESCRIPTION
    This script discovers present V340 devices, downloads or validates AMD's official
    22.Q4 package, extracts only the primary display-driver package, and changes the
    single hardware-ID revision match from REV_03 to REV_05.

    It does not create or trust a certificate, generate or sign a replacement catalog,
    change BCD/test-signing state, stage a driver, install a driver, or reboot Windows.
    The original Microsoft-signed catalog is moved into Evidence so the prepared folder
    cannot be mistaken for an installable package before a new catalog is generated.
#>

[CmdletBinding()]
param(
    [string] $InstallerPath,
    [string] $SevenZipPath,
    [string] $WorkingDirectory = (Join-Path $env:LOCALAPPDATA 'V340L-Enablement\AMD-PRO-22Q4'),
    [switch] $Json
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$officialUrl = 'https://drivers.amd.com/drivers/prographics/amd-software-pro-edition-22.q4-win10-win11-nov15.exe'
$releaseNotesUrl = 'https://www.amd.com/en/resources/support-articles/release-notes/RN-PRO-WIN-22-Q4.html'
$expectedBytes = 597154608L
$expectedSha256 = '04DB1EC2FBC1AAABDF22ACBF91BB914AC2E7140DDF241FC9418C2349335913C2'
$expectedInfSha256 = '8E809C34906D0E9361EA262F2F53D7B3898B22B7793E428110974057044BA27F'
$expectedCatalogSha256 = '684A7F6994FCE0E41F7B5CF932BA6B1ECCC441BBE2BBF872AAED8BEC89FB27E2'
$archiveInf = 'Packages\Drivers\Display\WT6A_INF\U0385558.inf'
$archiveCatalog = 'Packages\Drivers\Display\WT6A_INF\u0385558.cat'
$archivePayload = 'Packages\Drivers\Display\WT6A_INF\B385477\*'
$oldId = 'PCI\VEN_1002&DEV_6864&REV_03'
$newId = 'PCI\VEN_1002&DEV_6864&REV_05'

function Resolve-SevenZip([string] $RequestedPath) {
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $command = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }

    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles '7-Zip\7z.exe'),
        (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    throw "7z.exe is required to unpack AMD's NSIS package. Install 7-Zip from https://www.7-zip.org/ or pass -SevenZipPath."
}

function Find-ByteSequence([byte[]] $Haystack, [byte[]] $Needle) {
    $offsets = [Collections.Generic.List[int]]::new()
    for ($i = 0; $i -le $Haystack.Length - $Needle.Length; $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) { $offsets.Add($i) }
    }
    $offsets.ToArray()
}

if ([IntPtr]::Size -ne 8) { throw '64-bit PowerShell is required.' }

$v340Devices = @(
    Get-PnpDevice -PresentOnly -Class Display |
        Where-Object { $_.InstanceId -match '^PCI\\VEN_1002&DEV_6864' } |
        ForEach-Object {
            $hardwareIds = @(
                (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds').Data
            )
            [pscustomobject]@{
                FriendlyName = $_.FriendlyName
                InstanceId = $_.InstanceId
                HardwareIds = $hardwareIds
            }
        }
)
if ($v340Devices.Count -eq 0) { throw 'No present PCI\VEN_1002&DEV_6864 display devices were found.' }

$revisionIds = @(
    $v340Devices.HardwareIds |
        Where-Object { $_ -match '^PCI\\VEN_1002&DEV_6864.*&REV_[0-9A-F]{2}$' } |
        Sort-Object -Unique
)
if ($revisionIds.Count -ne 1 -or $revisionIds[0] -notmatch '&REV_05$') {
    throw "Expected every detected V340 to expose REV_05; found: $($revisionIds -join ', ')."
}

$sevenZip = Resolve-SevenZip $SevenZipPath
$workingRoot = [IO.Path]::GetFullPath($WorkingDirectory)
New-Item -ItemType Directory -Path $workingRoot -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path $workingRoot 'amd-software-pro-edition-22.q4-win10-win11-nov15.exe'
    if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
        $headers = @{
            Referer = $releaseNotesUrl
            Accept = 'application/octet-stream,application/x-msdownload,*/*'
        }
        $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/140.0 Safari/537.36'
        if (-not $Json) {
            Write-Host '[*] Downloading the official AMD Software: PRO Edition 22.Q4 package...' -ForegroundColor Cyan
        }
        Invoke-WebRequest -Uri $officialUrl -Headers $headers -UserAgent $userAgent -OutFile $InstallerPath -UseBasicParsing
    }
} else {
    $InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
}

$installer = Get-Item -LiteralPath $InstallerPath
$installerHash = (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash
$installerSignature = Get-AuthenticodeSignature -LiteralPath $installer.FullName
if ($installer.Length -ne $expectedBytes) { throw "Unexpected installer size: $($installer.Length); expected $expectedBytes." }
if ($installerHash -ne $expectedSha256) { throw "Unexpected installer SHA-256: $installerHash." }
if ($installerSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    $installerSignature.SignerCertificate.Subject -notmatch 'Advanced Micro Devices Inc\.') {
    throw "Installer Authenticode verification failed: $($installerSignature.Status), $($installerSignature.SignerCertificate.Subject)."
}

$runName = 'Prepared-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
$runRoot = Join-Path $workingRoot $runName
$extractRoot = Join-Path $runRoot 'Extracted'
$evidenceRoot = Join-Path $runRoot 'Evidence'
New-Item -ItemType Directory -Path $extractRoot,$evidenceRoot -Force | Out-Null

if (-not $Json) {
    Write-Host '[*] Extracting only U0385558.inf, its catalog, and B385477 payload...' -ForegroundColor Cyan
}
& $sevenZip x $installer.FullName "-o$extractRoot" "-ir!$archiveInf" "-ir!$archiveCatalog" "-ir!$archivePayload" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) { throw "7-Zip extraction failed with exit code $LASTEXITCODE." }

$packageRoot = Join-Path $extractRoot 'Packages\Drivers\Display\WT6A_INF'
$infPath = Join-Path $packageRoot 'U0385558.inf'
$catalogPath = Join-Path $packageRoot 'u0385558.cat'
if (-not (Test-Path -LiteralPath $infPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $catalogPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $packageRoot 'B385477') -PathType Container)) {
    throw 'The expected WT6A_INF driver package was not extracted.'
}

$pristineInfHash = (Get-FileHash -LiteralPath $infPath -Algorithm SHA256).Hash
$catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
if ($pristineInfHash -ne $expectedInfSha256) { throw "Unexpected pristine INF SHA-256: $pristineInfHash." }
if ($catalogHash -ne $expectedCatalogSha256) { throw "Unexpected stock catalog SHA-256: $catalogHash." }

$catalogSignature = Get-AuthenticodeSignature -LiteralPath $catalogPath
if ($catalogSignature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
    $catalogSignature.SignerCertificate.Subject -notmatch 'Microsoft Windows Hardware Compatibility Publisher') {
    throw "Stock catalog verification failed: $($catalogSignature.Status)."
}

$originalInfPath = Join-Path $evidenceRoot 'U0385558.inf.amd-original'
$originalCatalogPath = Join-Path $evidenceRoot 'U0385558.cat.amd-original'
Copy-Item -LiteralPath $infPath -Destination $originalInfPath
Move-Item -LiteralPath $catalogPath -Destination $originalCatalogPath

$bytes = [IO.File]::ReadAllBytes($infPath)
$oldBytes = [Text.Encoding]::ASCII.GetBytes($oldId)
$newBytes = [Text.Encoding]::ASCII.GetBytes($newId)
if ($oldBytes.Length -ne $newBytes.Length) { throw 'The revision substitution must be byte-for-byte equal length.' }
$oldOffsets = @(Find-ByteSequence $bytes $oldBytes)
$newOffsetsBefore = @(Find-ByteSequence $bytes $newBytes)
if ($oldOffsets.Count -ne 1 -or $newOffsetsBefore.Count -ne 0) {
    throw "Refusing ambiguous INF mutation: old matches=$($oldOffsets.Count), pre-existing new matches=$($newOffsetsBefore.Count)."
}
[Array]::Copy($newBytes, 0, $bytes, $oldOffsets[0], $newBytes.Length)
[IO.File]::WriteAllBytes($infPath, $bytes)

$patchedBytes = [IO.File]::ReadAllBytes($infPath)
$oldOffsetsAfter = @(Find-ByteSequence $patchedBytes $oldBytes)
$newOffsetsAfter = @(Find-ByteSequence $patchedBytes $newBytes)
if ($oldOffsetsAfter.Count -ne 0 -or $newOffsetsAfter.Count -ne 1) {
    throw 'INF readback verification failed.'
}

$diffPath = Join-Path $evidenceRoot 'REV_03-to-REV_05.diff'
@"
--- U0385558.inf.amd-original
+++ U0385558.inf
@@ hardware ID match @@
-$oldId
+$newId
"@ | Set-Content -LiteralPath $diffPath -Encoding ascii

$result = [pscustomobject]@{
    Status = 'PREPARED_NOT_INSTALLABLE'
    DetectedV340Devices = $v340Devices.Count
    DetectedRevisionHardwareId = $revisionIds[0]
    OfficialUrl = $officialUrl
    InstallerPath = $installer.FullName
    InstallerBytes = $installer.Length
    InstallerSHA256 = $installerHash
    InstallerSignature = [string]$installerSignature.Status
    InstallerSigner = $installerSignature.SignerCertificate.Subject
    SevenZipPath = $sevenZip
    SevenZipSHA256 = (Get-FileHash -LiteralPath $sevenZip -Algorithm SHA256).Hash
    PackageRoot = $packageRoot
    PayloadFiles = @(Get-ChildItem -LiteralPath (Join-Path $packageRoot 'B385477') -File).Count
    OriginalInfSHA256 = $pristineInfHash
    PatchedInfSHA256 = (Get-FileHash -LiteralPath $infPath -Algorithm SHA256).Hash
    OriginalCatalogSHA256 = $catalogHash
    OriginalCatalogSignature = [string]$catalogSignature.Status
    OriginalCatalogEvidencePath = $originalCatalogPath
    PatchByteOffset = $oldOffsets[0]
    Patch = "$oldId -> $newId"
    DiffReceipt = $diffPath
    CatalogPresentInPreparedPackage = Test-Path -LiteralPath $catalogPath
    NextRequiredGate = 'Generate a fresh catalog with Inf2Cat, test-sign it, and verify INF membership before changing boot policy.'
    MutationsPerformed = @('Created files under WorkingDirectory', 'Patched the extracted INF copy')
    SystemMutationsPerformed = @()
}

$receiptPath = Join-Path $evidenceRoot 'preparation-receipt.json'
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding utf8

if ($Json) {
    $result | ConvertTo-Json -Depth 6 -Compress
} else {
    Write-Host '[+] PREPARED, NOT INSTALLABLE' -ForegroundColor Green
    Write-Host "    Package : $packageRoot"
    Write-Host "    Patch   : $oldId -> $newId"
    Write-Host "    Receipt : $receiptPath"
    Write-Warning 'The stock catalog was deliberately removed from the prepared package. Generate and test-sign a new catalog before installation.'
    $result
}
