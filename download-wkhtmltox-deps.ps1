#!/usr/bin/env pwsh
# Downloads wkhtmltox and its missing shared-library dependencies
# for AlmaLinux/RHEL 8 x86_64 with mirror fallback.
#
# Usage (run once on a machine WITH internet access):
#   powershell -ExecutionPolicy Bypass -File .\resources\tools\download-wkhtmltox-deps.ps1
#
# Optional custom mirrors (e.g. internal Nexus/Artifactory):
#   powershell -ExecutionPolicy Bypass -File .\resources\tools\download-wkhtmltox-deps.ps1 -MirrorBaseUrls @("https://nexus.local/almalinux/8")

param(
    [string[]]$MirrorBaseUrls = @(
        "https://repo.almalinux.org/almalinux/8",
        "https://mirror.stream.centos.org/8-stream",
        "https://dl.rockylinux.org/pub/rocky/8"
    ),
    [string]$LocalPackageDir,
    [switch]$ListOnly
)

$outputDir = $PSScriptRoot   # resources/tools/
$targetTag = "el8"

$wkhtmltoxUrls = @(
    "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox-0.12.6.1-2.almalinux8.x86_64.rpm"
)

$repoMetadataCache = @{}

$dependencySpecs = @(
    # Direct missing .so dependencies (from ldd output)
    @{ repo = "AppStream"; names = @("libjpeg-turbo"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("libpng", "libpng15"); arches = @("x86_64") },
    @{ repo = "AppStream"; names = @("libXrender"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("fontconfig"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("freetype"); arches = @("x86_64") },
    @{ repo = "AppStream"; names = @("libXext"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("libX11"); arches = @("x86_64") },

    # Transitive deps (libX11 -> libxcb -> libXau)
    @{ repo = "BaseOS"; names = @("libxcb"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("libXau"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("libXdmcp"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("libX11-common"); arches = @("noarch") },

    # Runtime font packages required by wkhtmltox RPM dependencies
    @{ repo = "AppStream"; names = @("xorg-x11-fonts-75dpi"); arches = @("noarch") },
    @{ repo = "AppStream"; names = @("xorg-x11-fonts-Type1"); arches = @("noarch") },
    @{ repo = "AppStream"; names = @("xorg-x11-font-utils", "xorg-x11-utils"); arches = @("x86_64") },
    @{ repo = "AppStream"; names = @("fontpackages-filesystem"); arches = @("noarch") },

    # Missing deps frequently seen in offline installs
    @{ repo = "AppStream"; names = @("libfontenc"); arches = @("x86_64") },
    @{ repo = "AppStream"; names = @("ttmkfdir"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("pkgconf-pkg-config"); arches = @("x86_64") },
    @{ repo = "BaseOS"; names = @("dejavu-fonts-common"); arches = @("noarch") },
    @{ repo = "BaseOS"; names = @("dejavu-sans-fonts"); arches = @("noarch") }
)

function Test-RpmCompatibility {
    param(
        [string]$FileName,
        [string[]]$Names,
        [string[]]$Arches
    )

    $matchesName = $false
    foreach ($name in $Names) {
        if ($FileName.StartsWith("$name-")) {
            $matchesName = $true
            break
        }
    }
    if (-not $matchesName) { return $false }

    $matchesArch = $false
    foreach ($arch in $Arches) {
        if ($FileName -like "*.$arch.rpm") {
            $matchesArch = $true
            break
        }
    }
    if (-not $matchesArch) { return $false }

    return ($FileName -like "*.$targetTag.*.rpm" -or $FileName -like "*.noarch.rpm" -or $FileName -like "*almalinux8*.rpm")
}

function Get-MirrorRepoPackages {
    param(
        [string]$MirrorBase,
        [string]$RepoName
    )

    $cacheKey = "$MirrorBase|$RepoName"
    if ($repoMetadataCache.ContainsKey($cacheKey)) {
        return $repoMetadataCache[$cacheKey]
    }

    $repoRoot = "{0}/{1}/x86_64/os" -f $MirrorBase.TrimEnd('/'), $RepoName
    $repomdUrl = "$repoRoot/repodata/repomd.xml"

    try {
        $repomdText = (Invoke-WebRequest -Uri $repomdUrl -UseBasicParsing -TimeoutSec 60).Content
        [xml]$repomd = $repomdText

        $ns = New-Object System.Xml.XmlNamespaceManager($repomd.NameTable)
        $ns.AddNamespace("r", "http://linux.duke.edu/metadata/repo")
        $primaryNode = $repomd.SelectSingleNode("//r:data[@type='primary']/r:location", $ns)
        if ($null -eq $primaryNode) {
            throw "primary metadata entry not found"
        }

        $primaryHref = $primaryNode.GetAttribute("href")
        $primaryUrl = "$repoRoot/$primaryHref"
        $primaryGz = Join-Path $env:TEMP (([Guid]::NewGuid().ToString()) + ".xml.gz")

        Invoke-WebRequest -Uri $primaryUrl -OutFile $primaryGz -UseBasicParsing -TimeoutSec 120

        try {
            $fileStream = [System.IO.File]::OpenRead($primaryGz)
            $gzipStream = New-Object System.IO.Compression.GzipStream($fileStream, [System.IO.Compression.CompressionMode]::Decompress)
            $reader = New-Object System.IO.StreamReader($gzipStream)
            $primaryXmlText = $reader.ReadToEnd()
        }
        finally {
            if ($reader) { $reader.Dispose() }
            if ($gzipStream) { $gzipStream.Dispose() }
            if ($fileStream) { $fileStream.Dispose() }
            Remove-Item -Path $primaryGz -ErrorAction SilentlyContinue
        }

        [xml]$primary = $primaryXmlText
        $pns = New-Object System.Xml.XmlNamespaceManager($primary.NameTable)
        $pns.AddNamespace("c", "http://linux.duke.edu/metadata/common")

        $result = @()
        foreach ($pkgNode in $primary.SelectNodes("//c:package[@type='rpm']", $pns)) {
            $nameNode = $pkgNode.SelectSingleNode("c:name", $pns)
            $archNode = $pkgNode.SelectSingleNode("c:arch", $pns)
            $locNode = $pkgNode.SelectSingleNode("c:location", $pns)
            $timeNode = $pkgNode.SelectSingleNode("c:time", $pns)
            if ($null -eq $nameNode -or $null -eq $archNode -or $null -eq $locNode) { continue }

            $href = $locNode.GetAttribute("href")
            if ([string]::IsNullOrWhiteSpace($href)) { continue }

            $buildTime = 0
            if ($timeNode -ne $null) {
                [void][int64]::TryParse($timeNode.GetAttribute("build"), [ref]$buildTime)
            }

            $result += [pscustomobject]@{
                Name      = $nameNode.InnerText
                Arch      = $archNode.InnerText
                FileName  = [System.IO.Path]::GetFileName($href)
                Url       = "$repoRoot/$href"
                BuildTime = $buildTime
            }
        }

        $repoMetadataCache[$cacheKey] = $result
        return $result
    }
    catch {
        Write-Warning "Unable to read metadata from $repomdUrl : $($_.Exception.Message)"
        $repoMetadataCache[$cacheKey] = @()
        return @()
    }
}

function Resolve-DependencySources {
    param(
        [hashtable]$Spec,
        [string[]]$Mirrors,
        [string]$LocalDir
    )

    $candidateUrls = @()

    foreach ($mirror in $Mirrors) {
        $repoPkgs = Get-MirrorRepoPackages -MirrorBase $mirror -RepoName $Spec.repo
        $best = $repoPkgs |
            Where-Object { Test-RpmCompatibility -FileName $_.FileName -Names $Spec.names -Arches $Spec.arches } |
            Sort-Object BuildTime, FileName -Descending |
            Select-Object -First 1

        if ($best) {
            $candidateUrls += $best.Url
        }
    }

    $fileName = $null
    if ($candidateUrls.Count -gt 0) {
        $fileName = [System.IO.Path]::GetFileName($candidateUrls[0])
    }

    if (-not $fileName -and $LocalDir) {
        $localBest = Get-ChildItem -Path $LocalDir -Filter "*.rpm" -File -ErrorAction SilentlyContinue |
            Where-Object { Test-RpmCompatibility -FileName $_.Name -Names $Spec.names -Arches $Spec.arches } |
            Sort-Object Name -Descending |
            Select-Object -First 1

        if ($localBest) {
            $fileName = $localBest.Name
        }
    }

    if (-not $fileName) {
        return $null
    }

    return [pscustomobject]@{
        FileName = $fileName
        Urls     = $candidateUrls
    }
}

$packages = @()
$packages += @{ name = "wkhtmltox"; urls = $wkhtmltoxUrls }

foreach ($spec in $dependencySpecs) {
    $resolved = Resolve-DependencySources -Spec $spec -Mirrors $MirrorBaseUrls -LocalDir $LocalPackageDir
    if ($null -eq $resolved) {
        $failedName = "$($spec.repo):$($spec.names -join '|')"
        Write-Warning "Unable to resolve package for $failedName (compatible with $targetTag)"
        $packages += @{ name = $failedName; urls = @() }
        continue
    }

    $packages += @{ name = $resolved.FileName; urls = $resolved.Urls }
}

Write-Host "Downloading RPMs to: $outputDir"
Write-Host "Configured mirrors:"
$MirrorBaseUrls | ForEach-Object { Write-Host "  - $_" }
if ($LocalPackageDir) {
    Write-Host "Local package directory: $LocalPackageDir"
}

$failed = @()
foreach ($pkg in $packages) {
    $fileName = $pkg.name
    if ($pkg.urls.Count -gt 0) {
        $fileName = $pkg.urls[0].Split('/')[-1]
    }
    $destPath = Join-Path $outputDir $fileName

    if (Test-Path $destPath) {
        Write-Host "  [SKIP] $fileName (already exists)"
        continue
    }

    Write-Host "  [GET]  $fileName"
    if ($ListOnly) {
        if ($LocalPackageDir) {
            Write-Host "         -> local candidate: $(Join-Path $LocalPackageDir $fileName)"
        }
        if ($pkg.urls.Count -eq 0) {
            Write-Host "         -> candidate: <none found in configured mirrors>"
        } else {
            $pkg.urls | ForEach-Object { Write-Host "         -> candidate: $_" }
        }
        continue
    }

    if ($LocalPackageDir) {
        $localPath = Join-Path $LocalPackageDir $fileName
        if (Test-Path $localPath) {
            Copy-Item -Path $localPath -Destination $destPath -Force
            Write-Host "         -> OK from local dir: $localPath"
            continue
        }
    }

    if ($pkg.urls.Count -eq 0) {
        $failed += $fileName
        Write-Warning "         -> No mirror candidates resolved for $fileName"
        continue
    }

    $ok = $false
    foreach ($url in $pkg.urls) {
        try {
            Invoke-WebRequest -Uri $url -OutFile $destPath -UseBasicParsing -TimeoutSec 60
            Write-Host "         -> OK from $url"
            $ok = $true
            break
        } catch {
            Write-Warning "         -> FAILED from $url : $($_.Exception.Message)"
        }
    }

    if (-not $ok) {
        $failed += $fileName
        Write-Warning "         -> Unable to download $fileName from all configured sources"
    }
}

Write-Host ""
Write-Host "Done. RPMs in $outputDir :"
Get-ChildItem $outputDir -Filter "*.rpm" | Select-Object Name, @{N="Size(KB)";E={[math]::Round($_.Length/1KB,1)}}

if ($failed.Count -gt 0) {
    Write-Error "Missing packages: $($failed -join ', '). Add another mirror via -MirrorBaseUrls or download RPMs manually."
    exit 1
}

