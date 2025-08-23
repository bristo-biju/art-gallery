<#
Robust link checker for static HTML files (PowerShell)
- Scans .html files in the repository root (non-recursive) for href/src attributes
- Skips external links (http(s)://, //, mailto:, tel:, javascript:, data:)
- Verifies fragment-only links (#id) exist in the same file
- Resolves relative links and checks target file existence
- Returns exit code 0 when no broken links, 2 when broken links detected

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\link_check.ps1
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repoRoot = (Get-Location).ProviderPath
Write-Host "Running link check in: $repoRoot`n"

$htmlFiles = Get-ChildItem -Path $repoRoot -Filter *.html -File
if (!$htmlFiles -or $htmlFiles.Count -eq 0) { Write-Host "No .html files found in repo root."; exit 0 }

$broken = @()
$totalLinks = 0

# Regex to capture href or src attribute values (single or double quotes)
$attrPattern = '(?:href|src)\s*=\s*(?:"|\')(?<url>[^"\']+)(?:"|\')'
$attrRegex = [regex]::new($attrPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

foreach ($file in $htmlFiles) {
    $content = Get-Content -Raw -Encoding UTF8 -Path $file.FullName
    if ([string]::IsNullOrEmpty($content)) { continue }

    $matches = $attrRegex.Matches($content)
    foreach ($m in $matches) {
        $url = $m.Groups['url'].Value.Trim()
        if ([string]::IsNullOrEmpty($url)) { continue }
        $totalLinks++

        # Skip external/resource protocols we don't validate here
        if ($url -match '^(https?:\/\/|\/\/|mailto:|tel:|javascript:|data:)') {
            # handle fragment-only (starts with '#') separately
            if ($url.StartsWith('#')) {
                $frag = $url.TrimStart('#')
                if (-not [string]::IsNullOrEmpty($frag)) {
                    $foundFrag = ([regex]::IsMatch($content, "\bid\s*=\s*\"$([regex]::Escape($frag))\"")) -or ([regex]::IsMatch($content, "\bid\s*=\s*\'$([regex]::Escape($frag))\'")) -or ([regex]::IsMatch($content, "\bname\s*=\s*\"$([regex]::Escape($frag))\"")) -or ([regex]::IsMatch($content, "\bname\s*=\s*\'$([regex]::Escape($frag))\'"))
                    if (-not $foundFrag) {
                        $broken += [pscustomobject]@{file=$file.Name; type='fragment'; url=$url; note='fragment not found in same file'}
                    }
                }
            }
            continue
        }

        # Strip query string and fragment for file resolution
        $clean = $url -replace '\?.*$', '' -replace '#.*$', ''

        # Resolve absolute paths (starting with '/') relative to repo root
        if ($clean.StartsWith('/')) {
            $target = Join-Path $repoRoot ($clean.TrimStart('/'))
        } else {
            $baseDir = Split-Path -Parent $file.FullName
            $candidate = Join-Path $baseDir $clean
            $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue
            if ($null -ne $resolved) { $target = $resolved.ProviderPath } else { $target = $candidate }
        }

        # If target is a directory and not a file, check for index.html as a common default
        if (Test-Path $target -PathType Container) {
            $indexCandidate = Join-Path $target 'index.html'
            if (-not (Test-Path $indexCandidate)) {
                $broken += [pscustomobject]@{file=$file.Name; type='dir_no_index'; url=$url; resolved=$target}
            }
        } else {
            if (-not (Test-Path $target)) {
                $broken += [pscustomobject]@{file=$file.Name; type='file'; url=$url; resolved=$target}
            }
        }
    }
}

Write-Host "Total links scanned: $totalLinks`n"
if ($broken.Count -eq 0) {
    Write-Host "No broken local links or missing fragments found." -ForegroundColor Green
    exit 0
} else {
    Write-Host "Broken links found: $($broken.Count)" -ForegroundColor Red
    foreach ($b in $broken) {
        switch ($b.type) {
            'fragment' { Write-Host "[FRAGMENT MISSING] File: $($b.file) --> $($b.url)   ($($b.note))" -ForegroundColor Yellow }
            'dir_no_index' { Write-Host "[MISSING INDEX] File: $($b.file) --> $($b.url)   Resolved path: $($b.resolved)" -ForegroundColor Yellow }
            default { Write-Host "[MISSING FILE] File: $($b.file) --> $($b.url)   Resolved path: $($b.resolved)" -ForegroundColor Yellow }
        }
    }
    exit 2
}
