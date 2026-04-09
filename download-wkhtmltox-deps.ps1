<#
.SYNOPSIS
  Pobiera RPM-y potrzebne do uruchomienia Chromium (headless) na RHEL/UBI 8.

.DESCRIPTION
  Skrypt działa na Windows (PowerShell) i pobiera paczki RPM do katalogu docelowego,
  wykorzystując repozytoria UBI 8 (BaseOS + AppStream).

  Typowy use-case: sieć/CI nie ma dostępu do CDN RedHat z powodu błędu certyfikatu,
  więc pobierasz RPM-y w środowisku, które ma poprawny dostęp (np. poza MITM albo z
  właściwym CA), a potem commitujesz/archiwizujesz je i używasz offline podczas builda.

  Skrypt:
  - pobiera repodata (w tym primary.xml.gz)
  - parsuje listę pakietów i zależności (requires)
  - pobiera wszystkie potrzebne RPM-y (z obu repo)

  UWAGA:
  - Repo UBI jest publiczne, ale nadal może wymagać poprawnej walidacji TLS.
  - Skrypt nie wyłącza walidacji certyfikatów globalnie.

.PARAMETER Destination
  Katalog, do którego zostaną zapisane RPM-y.

.PARAMETER UbiRelease
  Wersja UBI8 (domyślnie 8).

.PARAMETER Arch
  Architektura (domyślnie x86_64).

.PARAMETER Packages
  Lista paczek do ściągnięcia (domyślnie: chromium + typowe zależności headless).

.PARAMETER WhatRequires
  Jeśli podasz nazwę capability (np. 'chromium'), skrypt spróbuje znaleźć pakiet dostarczający
  tę capability. Zwykle niepotrzebne.

.EXAMPLE
  # Pobranie RPM do resources/tools/chromium-rpms
  .\resources\tools\download-chromium-deps.ps1 -Destination .\resources\tools\chromium-rpms

.EXAMPLE
  # Pobranie tylko chromium i liberation-fonts
  .\resources\tools\download-chromium-deps.ps1 -Destination .\rpms -Packages chromium,liberation-fonts
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Destination,

  [ValidateSet('8')]
  [string]$UbiRelease = '8',

  [ValidateSet('x86_64')]
  [string]$Arch = 'x86_64',

  [string[]]$Packages = @(
    'chromium',
    'atk',
    'at-spi2-atk',
    'cups-libs',
    'fontconfig',
    'freetype',
    'gtk3',
    'libX11',
    'libXcomposite',
    'libXcursor',
    'libXdamage',
    'libXext',
    'libXi',
    'libXrandr',
    'libXrender',
    'libXtst',
    'libdrm',
    'mesa-libgbm',
    'nss',
    'pango',
    'xdg-utils',
    'liberation-fonts',
    'dejavu-sans-fonts'
  ),

  [string]$WhatRequires,

  # Opcjonalnie: alternatywny mirror / artifactory. Musi wskazywać na katalog nadrzędny
  # zawierający /baseos/os oraz /appstream/os.
  [string]$RepoBaseUrl,

  # Opcjonalnie: proxy dla Invoke-WebRequest, np. http://proxy:8080
  [string]$Proxy

  ,
  # Opcjonalnie: praca offline na już pobranym repodata (repomd.xml + primary.xml.gz)
  # Struktura jak na mirrorze: <OfflineRepoPath>/(baseos|appstream)/os/repodata/...
  [string]$OfflineRepoPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProgressPreference = 'SilentlyContinue'

function Write-Info([string]$Message) {
  Write-Host "[INFO] $Message"
}

function Write-Warn([string]$Message) {
  Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Err([string]$Message) {
  Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Invoke-Download([string]$Url, [string]$OutFile) {
  if (Test-Path -LiteralPath $OutFile) {
    return
  }
  Write-Info "GET $Url"
  $iwr = @{ Uri = $Url; OutFile = $OutFile; UseBasicParsing = $true }
  if ($Proxy) { $iwr.Proxy = $Proxy }
  Invoke-WebRequest @iwr
}

function Copy-IfMissing([string]$Src, [string]$Dst) {
  if (-not (Test-Path -LiteralPath $Dst)) {
    Copy-Item -LiteralPath $Src -Destination $Dst
  }
}

function Read-Xml([string]$Path) {
  [xml](Get-Content -LiteralPath $Path -Raw)
}

# UBI 8 public repos (lub mirror)
$BaseUrl = if ($RepoBaseUrl) { $RepoBaseUrl.TrimEnd('/') } else { "https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi$UbiRelease/$UbiRelease/$Arch" }
$Repos = @(
  @{ Name = 'baseos';    RepoId='ubi-8-baseos-rpms';    Url = "$BaseUrl/baseos/os" },
  @{ Name = 'appstream'; RepoId='ubi-8-appstream-rpms'; Url = "$BaseUrl/appstream/os" }
)

Ensure-Dir $Destination
$Cache = Join-Path $Destination ".cache"
Ensure-Dir $Cache

# --- Helpers to parse repodata ---

function Get-RepoMetadata([hashtable]$Repo) {
  $repodataDir = Join-Path $Cache ("repodata-" + $Repo.Name)
  Ensure-Dir $repodataDir

  $repomdFile = Join-Path $repodataDir "repomd.xml"

  if ($OfflineRepoPath) {
    $offlineRepomd = Join-Path $OfflineRepoPath ("{0}\\os\\repodata\\repomd.xml" -f $Repo.Name)
    if (-not (Test-Path -LiteralPath $offlineRepomd)) {
      throw "OfflineRepoPath wskazuje na brakujacy plik: $offlineRepomd"
    }
    Copy-IfMissing $offlineRepomd $repomdFile
  } else {
    $repomdUrl = "$($Repo.Url)/repodata/repomd.xml"
    Invoke-Download $repomdUrl $repomdFile
  }

  $repomd = Read-Xml $repomdFile
  $ns = New-Object System.Xml.XmlNamespaceManager($repomd.NameTable)
  $ns.AddNamespace('repo', 'http://linux.duke.edu/metadata/repo')

  $primaryNode = $repomd.SelectSingleNode("//repo:data[@type='primary']/repo:location", $ns)
  if (-not $primaryNode) {
    $primaryNode = $repomd.SelectSingleNode("/*[local-name()='repomd']/*[local-name()='data' and @type='primary']/*[local-name()='location']")
  }
  if (-not $primaryNode) { throw "Brak primary w repomd.xml dla repo $($Repo.Name)" }
  $primaryHref = $primaryNode.GetAttribute('href')

  $primaryGz = Join-Path $repodataDir (Split-Path $primaryHref -Leaf)
  if ($OfflineRepoPath) {
    $offlinePrimary = Join-Path $OfflineRepoPath ("{0}\\os\\{1}" -f $Repo.Name, ($primaryHref -replace '/', '\\'))
    if (-not (Test-Path -LiteralPath $offlinePrimary)) {
      throw "OfflineRepoPath wskazuje na brakujacy plik: $offlinePrimary"
    }
    Copy-IfMissing $offlinePrimary $primaryGz
  } else {
    $primaryUrl = "$($Repo.Url)/$primaryHref"
    Invoke-Download $primaryUrl $primaryGz
  }

  $primaryXml = Join-Path $repodataDir "primary.xml"
  if (-not (Test-Path -LiteralPath $primaryXml)) {
    Write-Info "Decompress $primaryGz"
    $gzStream = [System.IO.File]::OpenRead($primaryGz)
    try {
      $outStream = [System.IO.File]::Create($primaryXml)
      try {
        $gzip = New-Object System.IO.Compression.GzipStream($gzStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
          $gzip.CopyTo($outStream)
        } finally { $gzip.Dispose() }
      } finally { $outStream.Dispose() }
    } finally { $gzStream.Dispose() }
  }

  $primary = Read-Xml $primaryXml
  $ns2 = New-Object System.Xml.XmlNamespaceManager($primary.NameTable)
  $ns2.AddNamespace('common', 'http://linux.duke.edu/metadata/common')
  $ns2.AddNamespace('rpm', 'http://linux.duke.edu/metadata/rpm')

  $pkgCount = @($primary.SelectNodes('//common:package', $ns2)).Count
  if ($pkgCount -eq 0) {
    $pkgCount = @($primary.SelectNodes("//*[local-name()='package']")).Count
  }
  Write-Info "Repo $($Repo.Name): znaleziono pakietow w primary.xml = $pkgCount"
  if ($pkgCount -eq 0) {
    throw "primary.xml dla repo $($Repo.Name) nie zawiera zadnych pakietow (problem namespace/XPath lub uszkodzone repodata)."
  }

  return @{
    Repo = $Repo
    Primary = $primary
    Ns = $ns2
  }
}

function Get-PackageNodesByName($Meta, [string]$Name) {
  $nodes = $Meta.Primary.SelectNodes("//common:package[common:name='$Name']", $Meta.Ns)
  if (-not $nodes -or $nodes.Count -eq 0) {
    $nodes = $Meta.Primary.SelectNodes("//*[local-name()='package'][*[local-name()='name' and text()='$Name']]")
  }
  $nodes
}

function Get-PackageName($PkgNode, $Ns) {
  $nameNode = $PkgNode.SelectSingleNode('common:name', $Ns)
  if (-not $nameNode) { $nameNode = $PkgNode.SelectSingleNode("*[local-name()='name']") }
  if ($nameNode) { return $nameNode.InnerText }
  return ''
}

function Get-ProvidesCapabilities($PkgNode, $Ns) {
  $caps = @()
  $provideNodes = $PkgNode.SelectNodes('common:format/rpm:provides/rpm:entry', $Ns)
  if (-not $provideNodes -or $provideNodes.Count -eq 0) {
    $provideNodes = $PkgNode.SelectNodes("*[local-name()='format']/*[local-name()='provides']/*[local-name()='entry']")
  }
  foreach ($n in $provideNodes) {
    $caps += $n.GetAttribute('name')
  }
  return $caps
}

function Is-IgnorableCapability([string]$Name) {
  if (-not $Name) { return $true }
  if ($Name.StartsWith('/')) { return $true } # file path requires (zwykle z base image)
  if ($Name -like 'pkgconfig(*)') { return $true }
  if ($Name -match '\.so(\.|\(|$)') { return $true }
  return $false
}

function Get-RequireCapabilities($PkgNode, $Ns) {
  $caps = @()
  $reqNodes = $PkgNode.SelectNodes('common:format/rpm:requires/rpm:entry', $Ns)
  if (-not $reqNodes -or $reqNodes.Count -eq 0) {
    $reqNodes = $PkgNode.SelectNodes("*[local-name()='format']/*[local-name()='requires']/*[local-name()='entry']")
  }
  foreach ($n in $reqNodes) {
    $name = $n.GetAttribute('name')
    if ($name -and
        ($name -notlike 'rpmlib(*)') -and
        ($name -notlike 'config(*)') -and
        ($name -notlike 'post(*)') -and
        ($name -notlike 'pre(*)') -and
        (-not (Is-IgnorableCapability $name))) {
      $caps += $name
    }
  }
  return $caps
}

function Get-PackageDownloadInfo($PkgNode, $RepoUrl, $Ns) {
  $loc = $PkgNode.SelectSingleNode('common:location', $Ns)
  if (-not $loc) { $loc = $PkgNode.SelectSingleNode("*[local-name()='location']") }
  if (-not $loc) { return $null }
  $href = $loc.GetAttribute('href')
  $fileName = Split-Path $href -Leaf
  return @{
    FileName = $fileName
    Href = $href
    Url = "$RepoUrl/$href"
  }
}

# Build metadata for both repos
$Metas = @()
foreach ($r in $Repos) {
  try {
    Write-Info "Loading repodata: $($r.Name)"
    $Metas += (Get-RepoMetadata $r)
  } catch {
    Write-Err "Nie udalo sie pobrac repodata dla $($r.Name): $($_.Exception.Message)"
    throw
  }
}

# Index: capability -> package node (first win)
$ProvideIndex = @{}
$NameIndex = @{}

function Get-PackageArch($PkgNode, $Ns) {
  $archNode = $PkgNode.SelectSingleNode('common:arch', $Ns)
  if (-not $archNode) { $archNode = $PkgNode.SelectSingleNode("*[local-name()='arch']") }
  if ($archNode) { return $archNode.InnerText }
  return ''
}

function Get-ArchPriority([string]$Arch) {
  switch ($Arch) {
    'x86_64' { return 0 }
    'noarch' { return 1 }
    'i686'   { return 9 }
    default  { return 5 }
  }
}
foreach ($m in $Metas) {
  $pkgs = $m.Primary.SelectNodes('//common:package', $m.Ns)
  if (-not $pkgs -or $pkgs.Count -eq 0) {
    $pkgs = $m.Primary.SelectNodes("//*[local-name()='package']")
  }
  foreach ($p in $pkgs) {
    $name = Get-PackageName $p $m.Ns
    if (-not $name) { continue }
    if (-not $NameIndex.ContainsKey($name)) {
      $NameIndex[$name] = @()
    }
    $NameIndex[$name] += @([pscustomobject]@{ Meta = $m; Node = $p })

    foreach ($cap in (Get-ProvidesCapabilities $p $m.Ns)) {
      if (-not $ProvideIndex.ContainsKey($cap)) { $ProvideIndex[$cap] = @() }
      $ProvideIndex[$cap] += @([pscustomobject]@{ Meta = $m; Node = $p })
    }
  }
}

$PackageAliases = @{
  'chromium' = @('chromium', 'chromium-browser', 'chromium-headless', 'google-chrome-stable', 'google-chrome')
  'xdg-utils' = @('xdg-utils', 'xdg-utils-minimal')
  'liberation-fonts' = @('liberation-fonts', 'liberation-sans-fonts', 'liberation-serif-fonts', 'liberation-mono-fonts')
}

function Resolve-Package([string]$NameOrCap) {
  $namesToTry = @($NameOrCap)
  if ($PackageAliases.ContainsKey($NameOrCap)) {
    $namesToTry = @($PackageAliases[$NameOrCap])
  }

  foreach ($name in $namesToTry) {
    if ($NameIndex.ContainsKey($name)) {
      $candidates = $NameIndex[$name]
      # defensywnie odfiltruj niepoprawne wpisy (np. puste/nieoczekiwany typ)
      $candidates = @($candidates | Where-Object {
        if (-not $_) { return $false }
        if ($_ -is [System.Collections.IDictionary]) {
          return $_.Contains('Meta') -and $_.Contains('Node')
        }
        return ($_.PSObject.Properties.Match('Meta').Count -gt 0) -and ($_.PSObject.Properties.Match('Node').Count -gt 0)
      })
      # prefer: repo appstream, then arch x86_64/noarch, then anything else
      $sorted = @($candidates | Sort-Object `
        @{ Expression = { $_.Meta.Repo.Name -ne 'appstream' }; Ascending = $true }, `
        @{ Expression = { Get-ArchPriority (Get-PackageArch $_.Node $_.Meta.Ns) }; Ascending = $true })
      if ($sorted.Count -gt 0) {
        $best = $sorted[0]
        $arch = Get-PackageArch $best.Node $best.Meta.Ns
        if ($arch -ne 'i686') { return $best }
      }
    }

    if ($ProvideIndex.ContainsKey($name)) {
      $candidates = $ProvideIndex[$name]
      $candidates = @($candidates | Where-Object {
        if (-not $_) { return $false }
        if ($_ -is [System.Collections.IDictionary]) {
          return $_.Contains('Meta') -and $_.Contains('Node')
        }
        return ($_.PSObject.Properties.Match('Meta').Count -gt 0) -and ($_.PSObject.Properties.Match('Node').Count -gt 0)
      })
      $sorted = @($candidates | Sort-Object `
        @{ Expression = { $_.Meta.Repo.Name -ne 'appstream' }; Ascending = $true }, `
        @{ Expression = { Get-ArchPriority (Get-PackageArch $_.Node $_.Meta.Ns) }; Ascending = $true })
      if ($sorted.Count -gt 0) {
        $best = $sorted[0]
        $arch = Get-PackageArch $best.Node $best.Meta.Ns
        if ($arch -ne 'i686') { return $best }
      }
    }
  }

  return $null
}

# Optionally find provider for a given capability
if ($WhatRequires) {
  $prov = Resolve-Package $WhatRequires
  if (-not $prov) {
    Write-Err "Nie znaleziono providera dla capability: $WhatRequires"
    exit 2
  }
  $n = Get-PackageName $prov.Node $prov.Meta.Ns
  Write-Info "Provider for '$WhatRequires' => package: $n (repo: $($prov.Meta.Repo.Name))"
}

# BFS dependency resolution
$Queue = New-Object System.Collections.Generic.Queue[string]
$Visited = New-Object 'System.Collections.Generic.HashSet[string]'
$Selected = @{} # pkgName -> {Meta,Node}

foreach ($p in $Packages) { $Queue.Enqueue($p) }

while ($Queue.Count -gt 0) {
  $item = $Queue.Dequeue()
  if ($Visited.Contains($item)) { continue }
  $null = $Visited.Add($item)

  $resolved = Resolve-Package $item
  if (-not $resolved) {
    Write-Warn "Nie znaleziono pakietu/capability: $item (pomijam)"
    continue
  }

  $pkgName = Get-PackageName $resolved.Node $resolved.Meta.Ns
  if (-not $pkgName) {
    Write-Warn "Pominieto wpis bez nazwy pakietu dla capability: $item"
    continue
  }
  if (-not $Selected.ContainsKey($pkgName)) {
    $Selected[$pkgName] = $resolved

    $requires = Get-RequireCapabilities $resolved.Node $resolved.Meta.Ns
    foreach ($req in $requires) {
      if (-not $Visited.Contains($req)) {
        $Queue.Enqueue($req)
      }
    }
  }
}

Write-Info "Do pobrania pakietow: $($Selected.Keys.Count)"

if ($Selected.Keys.Count -eq 0) {
  Write-Err "Nie wybrano zadnych pakietow do pobrania. Sprawdz: (1) czy repo zawiera chromium dla UBI8; (2) czy Arch jest poprawny; (3) czy OfflineRepoPath/RepoBaseUrl wskazuje na poprawny mirror."
  exit 3
}

# Download RPM files
foreach ($kv in $Selected.GetEnumerator()) {
  $pkg = $kv.Value
  $info = Get-PackageDownloadInfo $pkg.Node $pkg.Meta.Repo.Url $pkg.Meta.Ns
  if (-not $info) {
    Write-Warn "Brak location dla pakietu: $($kv.Key)"
    continue
  }

  $out = Join-Path $Destination $info.FileName
  try {
    Invoke-Download $info.Url $out
  } catch {
    Write-Err "Nie udalo sie pobrac $($info.Url): $($_.Exception.Message)"
    throw
  }
}

Write-Info "Gotowe. RPM-y sa w: $Destination"
Write-Info "Wskazowka: skopiuj te RPM do resources/tools/ lub osobnego katalogu i dostosuj Dockerfile do instalacji offline."

