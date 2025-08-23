<#
sync_and_push.ps1
Safe Git sync + optional image download + push script for Windows PowerShell (repo root)

Usage (from repository root):
  .\scripts\sync_and_push.ps1            # interactive mode
  .\scripts\sync_and_push.ps1 -AutoConfirm -RunDownload -PushRemote

Parameters:
  -AutoConfirm    : Skip interactive Y/N prompts (use carefully).
  -RunDownload    : After merging, run scripts\download_wikimedia_images.ps1 with -AutoCommit to add images and update HTML.
  -PushRemote     : After successful sync, push "main" to origin automatically.
  -RemoteName     : Git remote name (default: origin)
  -BackupBranch   : Name of your backup branch (default: backup-main-before-sync)

Behavior summary:
  1. Verifies git present and we are in a git repo.
  2. Fetches origin and shows current branches/status.
  3. Ensures a backup branch exists (creates one if missing from current HEAD).
  4. Switches to local main (creates tracking branch if needed) and rebases onto origin/main.
  5. Merges backup branch into main.
  6. Optionally runs the download script (which can auto-commit).
  7. Optionally pushes main to origin (with retry if non-fast-forward by rebasing again).

Important safety notes:
  - On conflicts during rebase/merge the script will stop so you can resolve them manually.
  - Review changes before pushing when not using -AutoConfirm.
#>

param(
    [switch]$AutoConfirm,
    [switch]$RunDownload,
    [switch]$PushRemote,
    [string]$RemoteName = 'origin',
    [string]$BackupBranch = 'backup-main-before-sync'
)

function AbortWith($msg) {
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

# Ensure git is available
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    AbortWith 'Git is not installed or not in PATH. Install Git and re-run.'
}

$repoRoot = (Get-Location).ProviderPath
# Basic sanity: require .git or index.html
if (-not (Test-Path (Join-Path $repoRoot '.git'))) {
    if (-not (Test-Path (Join-Path $repoRoot 'index.html'))) {
        AbortWith "This does not look like the repository root. Run the script from the repository root."
    }
}

Write-Host "Repository root: $repoRoot" -ForegroundColor Cyan

# Show current status and branches
Write-Host "\nCurrent Git status and branches:\n" -ForegroundColor Cyan
git status --porcelain=v1
git branch --verbose --all

if (-not $AutoConfirm) {
    $ok = Read-Host "Proceed with fetch/rebase/merge workflow? (y/n)"
    if ($ok -notin @('y','Y','yes','Yes')) { Write-Host 'Aborted by user.'; exit 0 }
}

# Fetch remote
Write-Host "\nFetching $RemoteName..." -ForegroundColor Cyan
$fetchRes = git fetch $RemoteName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $fetchRes
    AbortWith "git fetch failed. Check network/remote and try again."
}

# Ensure backup branch exists locally
$branches = git branch --list $BackupBranch
if ([string]::IsNullOrEmpty($branches)) {
    Write-Host "Backup branch '$BackupBranch' not found. Creating it from current HEAD." -ForegroundColor Yellow
    git branch $BackupBranch
    if ($LASTEXITCODE -ne 0) { AbortWith "Failed to create backup branch $BackupBranch" }
} else {
    Write-Host "Backup branch '$BackupBranch' exists. Leaving it intact." -ForegroundColor Green
}

# Switch to main (create tracking if needed)
$localMainExists = -not [string]::IsNullOrEmpty( (git branch --list main) )
if ($localMainExists) {
    Write-Host "Switching to local 'main'..." -ForegroundColor Cyan
    git switch main
    if ($LASTEXITCODE -ne 0) { AbortWith "Failed to switch to local 'main'" }
} else {
    Write-Host "Local 'main' not found. Creating 'main' tracking '$RemoteName/main'..." -ForegroundColor Cyan
    git switch --track -c main $RemoteName/main
    if ($LASTEXITCODE -ne 0) { AbortWith "Failed to create local 'main' tracking $RemoteName/main" }
}

# Rebase local main onto origin/main
Write-Host "Rebasing local 'main' onto $RemoteName/main..." -ForegroundColor Cyan
$rebaseOutput = git rebase $RemoteName/main 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $rebaseOutput
    AbortWith "Rebase failed or encountered conflicts. Resolve conflicts manually, then run: git rebase --continue" 
}
Write-Host "Rebase completed successfully." -ForegroundColor Green

# Merge backup branch into main
Write-Host "Merging '$BackupBranch' into 'main' (no-fast-forward)..." -ForegroundColor Cyan
$mergeOutput = git merge --no-ff $BackupBranch -m "Merge local edits from $BackupBranch into main" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host $mergeOutput
    AbortWith "Merge failed or conflicts detected. Resolve conflicts, then run: git merge --continue (or commit after resolving)"
}
Write-Host "Merge completed successfully." -ForegroundColor Green

# Optionally run download script
if ($RunDownload) {
    $downloadScript = Join-Path $repoRoot 'scripts\download_wikimedia_images.ps1'
    if (-not (Test-Path $downloadScript)) {
        Write-Host "Download script not found at $downloadScript" -ForegroundColor Yellow
    } else {
        Write-Host "Running download script (will auto-commit downloaded images/HTML updates)..." -ForegroundColor Cyan
        $psExe = (Get-Command powershell -ErrorAction SilentlyContinue) -or (Get-Command pwsh -ErrorAction SilentlyContinue)
        # Run with bypassed policy to prevent ExecutionPolicy issues
        powershell -ExecutionPolicy Bypass -File $downloadScript -AutoCommit -CommitMessage "Add Wikimedia images and update HTML references"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Download script finished with non-zero exit code. Inspect output and commit state." -ForegroundColor Yellow
        } else {
            Write-Host "Download script completed." -ForegroundColor Green
        }
    }
}

# Show final status and diff summary
Write-Host "\nFinal git status (short):" -ForegroundColor Cyan
git status --porcelain=v1

if ($PushRemote) {
    if (-not $AutoConfirm) {
        $ok2 = Read-Host "Push local 'main' to $RemoteName/main now? (y/n)"
        if ($ok2 -notin @('y','Y','yes','Yes')) { Write-Host 'Push aborted by user.'; exit 0 }
    }

    Write-Host "Pushing 'main' to $RemoteName/main..." -ForegroundColor Cyan
    git push $RemoteName main 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Initial push failed. Attempting a safe fetch+rebase and retry..." -ForegroundColor Yellow
        git fetch $RemoteName
        if ($LASTEXITCODE -ne 0) { AbortWith "Fetch failed during push-retry." }
        git rebase $RemoteName/main
        if ($LASTEXITCODE -ne 0) { AbortWith "Rebase during push-retry failed. Resolve conflicts manually and retry push." }
        git push $RemoteName main
        if ($LASTEXITCODE -ne 0) { AbortWith "Push retry failed. Inspect remote and local history before forcing." }
    }
    Write-Host "Push succeeded." -ForegroundColor Green
}

Write-Host "\nWorkflow complete. Inspect your repo and, if desired, enable GitHub Pages in repository settings." -ForegroundColor Cyan
Write-Host "If the script stopped due to conflicts, resolve them manually and re-run the script or run git rebase --continue / git merge --continue as appropriate." -ForegroundColor Yellow

exit 0
