#Requires -RunAsAdministrator
# =============================================================================
# deploy-app.ps1 — Incremental deployment for ecomm
# Run by the GitHub Actions deploy job on every push to main.
# Assumes setup-vm.ps1 has already run successfully.
# =============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$LogFile = "C:\deploy\deploy.log"

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Tee-Object -FilePath $LogFile -Append
}

Write-Log "=== deploy-app.ps1 started ==="

# =============================================================================
# STEP 1 — Stop PM2 app gracefully
# =============================================================================
Write-Log "Stopping PM2 app: ecomm-api"
pm2 stop ecomm-api
if ($LASTEXITCODE -ne 0) {
    Write-Log "WARNING: pm2 stop returned $LASTEXITCODE (app may not have been running — continuing)"
}

# =============================================================================
# STEP 2 — Deploy frontend dist to IIS web root
# /MIR: mirror the source (deletes removed files), /NP: no progress bar
# /XD: exclude hidden/system dirs if any
# =============================================================================
Write-Log "Deploying frontend dist..."
$frontendSrc  = "C:\deploy\frontend-dist\"
$frontendDest = "C:\inetpub\wwwroot\ecomm\"

New-Item -ItemType Directory -Force -Path $frontendDest | Out-Null

Robocopy $frontendSrc $frontendDest /MIR /NP /NFL /NDL /NJH /LOG+:$LogFile
# Robocopy exit codes 0-7 are success (bitmask of what was copied/skipped)
if ($LASTEXITCODE -gt 7) {
    throw "Robocopy (frontend) failed with exit code $LASTEXITCODE"
}
Write-Log "Frontend deployed to $frontendDest"

# =============================================================================
# STEP 3 — Deploy backend source (exclude node_modules)
# =============================================================================
Write-Log "Deploying backend source..."
$backendSrc  = "C:\deploy\backend-upload\"
$backendDest = "C:\deploy\backend\"

New-Item -ItemType Directory -Force -Path $backendDest | Out-Null

Robocopy $backendSrc $backendDest /MIR /NP /NFL /NDL /NJH `
    /XD node_modules /LOG+:$LogFile
if ($LASTEXITCODE -gt 7) {
    throw "Robocopy (backend) failed with exit code $LASTEXITCODE"
}
Write-Log "Backend source deployed to $backendDest"

# =============================================================================
# STEP 4 — Install production dependencies
# --omit=dev: do not install devDependencies on the production VM
# =============================================================================
Write-Log "Installing backend production dependencies..."
Set-Location $backendDest
npm install --omit=dev --no-fund --no-audit
Write-Log "npm install complete."

# =============================================================================
# STEP 5 — Start PM2 app
# =============================================================================
Write-Log "Starting PM2 app: ecomm-api"
pm2 start ecomm-api
if ($LASTEXITCODE -ne 0) {
    throw "pm2 start ecomm-api failed with exit code $LASTEXITCODE"
}

# Persist PM2 process list so it survives reboots
pm2 save
Write-Log "PM2 ecomm-api started and process list saved."

# =============================================================================
# STEP 6 — Reload IIS to pick up any web.config changes (non-disruptive)
# /noforce: waits for active requests to complete before restarting workers
# =============================================================================
Write-Log "Reloading IIS..."
iisreset /noforce
Write-Log "IIS reloaded."

Write-Log "=== deploy-app.ps1 completed successfully ==="
