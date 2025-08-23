<#
PowerShell script: download_wikimedia_images.ps1

Usage (from repo root):
  .\scripts\download_wikimedia_images.ps1 [-AutoCommit] [-CommitMessage "Message"]

Notes:
#>

param(
    [switch]$AutoCommit,
    [string]$CommitMessage = "Add Wikimedia images and update HTML references"
)

# Ensure TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repoRoot = (Get-Location).ProviderPath
$scriptsDir = Join-Path $repoRoot 'scripts'
$imagesDir = Join-Path $repoRoot 'assets\images'

if (-not (Test-Path $imagesDir)) {
    New-Item -ItemType Directory -Path $imagesDir | Out-Null
}

# Find HTML files in root (not recursing into assets/) -- adjust pattern if you store pages elsewhere
$htmlFiles = Get-ChildItem -Path $repoRoot -Filter *.html -File

$wikimediaPattern = 'https?://upload.wikimedia.org[^"\s>]+'
$downloaded = @{}
$urls = @()

foreach ($file in $htmlFiles) {
    $content = Get-Content -Raw -Encoding UTF8 -Path $file.FullName
    $found = [regex]::Matches($content, $wikimediaPattern)
    foreach ($m in $found) {
        $url = $m.Value
        if (-not $urls.Contains($url)) { $urls += $url }
    }
}

if ($urls.Count -eq 0) {
    Write-Host "No Wikimedia image URLs found in HTML files. Nothing to do." -ForegroundColor Yellow
    return
}

foreach ($url in $urls) {
    try {
        $uri = [uri]$url
    } catch {
        Write-Warning "Skipping invalid URL: $url"
        continue
    }

    $fileName = [System.IO.Path]::GetFileName($uri.LocalPath)
    if ([string]::IsNullOrEmpty($fileName)) {
        # fallback name
        $fileName = [System.Guid]::NewGuid().ToString() + '.img'
    }

    $localPath = Join-Path $imagesDir $fileName
    $relativePath = "assets/images/$fileName"    # forward slashes for HTML

    if (-not (Test-Path $localPath)) {
        Write-Host "Downloading $url -> $relativePath"
        try {
            Invoke-WebRequest -Uri $url -OutFile $localPath -UseBasicParsing -ErrorAction Stop
            $downloaded[$url] = $relativePath
        } catch {
            Write-Warning "Failed to download $url : $_"
            continue
        }
    } else {
        Write-Host "File already exists, skipping download: $relativePath"
        $downloaded[$url] = $relativePath
    }
}

# Replace URLs in HTML files with local relative paths
foreach ($file in $htmlFiles) {
    $content = Get-Content -Raw -Encoding UTF8 -Path $file.FullName
    $updated = $content
    foreach ($kv in $downloaded.GetEnumerator()) {
        $remote = $kv.Key
        $local = $kv.Value -replace '\\','/'   # ensure forward slashes
        $updated = $updated.Replace($remote, $local)
    }

    if ($updated -ne $content) {
        Set-Content -Path $file.FullName -Value $updated -Encoding UTF8
        Write-Host "Updated HTML file: $($file.Name)"
    }
}

# Stage and commit using git if requested
if ($AutoCommit) {
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Push-Location $repoRoot
        try {
            git add "assets/images" *.html | Out-Null
            git commit -m $CommitMessage
            Write-Host "Staged and committed images + updated HTML with message: $CommitMessage" -ForegroundColor Green
        } catch {
            Write-Warning "Git commit failed or nothing to commit: $_"
        } finally {
            Pop-Location
        }
    } else {
        Write-Warning "Git not found in PATH. Install Git or run git add/commit manually."
    }
}

Write-Host "Done. Downloaded $($downloaded.Keys.Count) image(s)." -ForegroundColor Cyan
