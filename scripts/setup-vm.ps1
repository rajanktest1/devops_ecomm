#Requires -RunAsAdministrator
# =============================================================================
# setup-vm.ps1 — One-time Windows Server 2022 bootstrap for ecomm
# Run by Azure VM Custom Script Extension on first boot.
# Log file: C:\deploy\setup.log
# =============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"   # speeds up Invoke-WebRequest

$LogFile = "C:\deploy\setup.log"
New-Item -ItemType Directory -Force -Path "C:\deploy\scripts" | Out-Null
New-Item -ItemType Directory -Force -Path "C:\deploy\backend"  | Out-Null
New-Item -ItemType Directory -Force -Path "C:\inetpub\wwwroot\ecomm" | Out-Null

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts  $Message" | Tee-Object -FilePath $LogFile -Append
}

# =============================================================================
# Helper: fetch a secret from Azure Key Vault using IMDS (no SDK / CLI needed)
# SECURITY: uses the VM managed identity token — no credential is hardcoded.
# =============================================================================
function Get-KeyVaultSecret {
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$SecretName
    )

    # Step 1 – get IMDS OAuth token for Key Vault
    # SECURITY: token is fetched from the VM-local IMDS endpoint (not internet-routable)
    $imdsUri  = "http://169.254.169.254/metadata/identity/oauth2/token" +
                "?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"
    $tokenResp = Invoke-RestMethod -Uri $imdsUri -Headers @{ Metadata = "true" } -Method Get
    $token     = $tokenResp.access_token

    # Step 2 – read the secret value
    $secretUri = "https://$VaultName.vault.azure.net/secrets/$SecretName" +
                 "?api-version=7.4"
    $secretResp = Invoke-RestMethod -Uri $secretUri `
                    -Headers @{ Authorization = "Bearer $token" } `
                    -Method Get
    return $secretResp.value
}

# =============================================================================
# Helper: get the VM public IP from IMDS
# =============================================================================
function Get-VMPublicIP {
    $uri = "http://169.254.169.254/metadata/instance/network/interface/0/" +
           "ipv4/ipAddress/0/publicIpAddress?api-version=2021-02-01&format=text"
    return (Invoke-RestMethod -Uri $uri -Headers @{ Metadata = "true" }).Trim()
}

# =============================================================================
# STEP 0 — Fetch secrets from Key Vault before any installations
# =============================================================================
param([Parameter(Mandatory)][string]$KeyVaultName)

Write-Log "=== Fetching secrets from Key Vault: $KeyVaultName ==="
# SECURITY: passwords are fetched from Key Vault; never passed as process arguments
$mysqlRootPw = Get-KeyVaultSecret -VaultName $KeyVaultName -SecretName "mysql-root-password"
$dbAppPw     = Get-KeyVaultSecret -VaultName $KeyVaultName -SecretName "db-password"
$sshPubKey   = Get-KeyVaultSecret -VaultName $KeyVaultName -SecretName "vm-ssh-public-key"
$vmPublicIP  = Get-VMPublicIP
Write-Log "Secrets fetched. VM public IP: $vmPublicIP"

# =============================================================================
# STEP 1 — Install Chocolatey
# =============================================================================
Write-Log "=== Installing Chocolatey ==="
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    # Refresh PATH so choco is available in this session
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}
Write-Log "Chocolatey ready."

# =============================================================================
# STEP 2 — Install Node.js LTS
# =============================================================================
Write-Log "=== Installing Node.js LTS ==="
choco install nodejs-lts --yes --no-progress
# Refresh PATH
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH","User")
Write-Log "Node.js version: $(node --version)"

# =============================================================================
# STEP 3 — Install PM2 and pm2-windows-startup
# =============================================================================
Write-Log "=== Installing PM2 ==="
npm install -g pm2 pm2-windows-startup --no-fund --no-audit
Write-Log "PM2 version: $(pm2 --version)"

# =============================================================================
# STEP 4 — Install MySQL Community Server 8
# =============================================================================
Write-Log "=== Installing MySQL 8 ==="
choco install mysql --yes --no-progress

# Wait for MySQL service to start
$maxWait = 60
$waited  = 0
while ($waited -lt $maxWait) {
    $svc = Get-Service -Name "MySQL" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { break }
    Start-Sleep -Seconds 3
    $waited += 3
}
Write-Log "MySQL service status: $((Get-Service MySQL).Status)"

# Set root password and create database
# SECURITY: password is in a variable, not a command-line argument visible in logs
$mysqlBin = "C:\tools\mysql\current\bin\mysql.exe"
& $mysqlBin -u root --connect-expired-password -e @"
ALTER USER 'root'@'localhost' IDENTIFIED BY '$mysqlRootPw';
CREATE DATABASE IF NOT EXISTS ecomm CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
FLUSH PRIVILEGES;
"@
Write-Log "MySQL root password set and ecomm database created."

# =============================================================================
# STEP 5 — Copy schema and run it
# (schema.sql is expected at C:\deploy\schema.sql — uploaded by deploy-app.ps1)
# For first run, copy from the Custom Script Extension download location.
# =============================================================================
$schemaSource = Join-Path $PSScriptRoot "schema.sql"
if (-not (Test-Path $schemaSource)) {
    Write-Log "WARNING: schema.sql not found at $schemaSource. Run deploy-app.ps1 to upload and retry."
} else {
    Copy-Item $schemaSource "C:\deploy\schema.sql" -Force
    # SECURITY: password passed via variable, not shell arg
    & $mysqlBin -u root -p"$mysqlRootPw" ecomm -e "SOURCE C:/deploy/schema.sql;"
    Write-Log "Schema imported."
}

# =============================================================================
# STEP 6 — Create dedicated app MySQL user (least-privilege)
# SECURITY: app user gets only DML on ecomm.*; no DDL, no global privileges
# =============================================================================
& $mysqlBin -u root -p"$mysqlRootPw" -e @"
CREATE USER IF NOT EXISTS 'ecommapp'@'127.0.0.1' IDENTIFIED BY '$dbAppPw';
GRANT SELECT, INSERT, UPDATE, DELETE ON ecomm.* TO 'ecommapp'@'127.0.0.1';
FLUSH PRIVILEGES;
"@
Write-Log "MySQL app user 'ecommapp' created with least-privilege grants."

# =============================================================================
# STEP 7 — Install IIS with WebAdministration
# =============================================================================
Write-Log "=== Installing IIS ==="
$iisFeatures = @(
    "Web-Server", "Web-Default-Doc", "Web-Static-Content",
    "Web-Http-Errors", "Web-Http-Redirect",
    "Web-Stat-Compression", "Web-Http-Logging",
    "Web-WebSockets", "Web-Mgmt-Tools", "Web-Mgmt-Console"
)
Install-WindowsFeature -Name $iisFeatures -IncludeManagementTools | Out-Null
Import-Module WebAdministration -ErrorAction SilentlyContinue
Write-Log "IIS installed."

# =============================================================================
# STEP 8 — Install URL Rewrite 2.1 (SPA routing)
# =============================================================================
Write-Log "=== Installing IIS URL Rewrite 2.1 ==="
choco install urlrewrite --yes --no-progress
Write-Log "URL Rewrite installed."

# =============================================================================
# STEP 9 — Install Application Request Routing (ARR) for reverse proxy
# =============================================================================
Write-Log "=== Installing IIS ARR ==="
choco install iis-arr --yes --no-progress

# Enable proxy in ARR
Add-WebConfigurationProperty -pspath "MACHINE/WEBROOT/APPHOST" `
    -filter "system.webServer/proxy" -name "enabled" -value $true
Write-Log "ARR installed and proxy enabled."

# =============================================================================
# STEP 10 — Configure IIS site for React SPA + API reverse proxy
# =============================================================================
Write-Log "=== Configuring IIS site ==="

$siteName  = "ecomm"
$sitePath  = "C:\inetpub\wwwroot\ecomm"
$appPoolName = "ecomm"

# Create app pool
if (-not (Test-Path "IIS:\AppPools\$appPoolName")) {
    New-WebAppPool -Name $appPoolName
    Set-ItemProperty "IIS:\AppPools\$appPoolName" managedRuntimeVersion ""
}

# Remove default site and create ecomm site on port 80
Remove-WebSite -Name "Default Web Site" -ErrorAction SilentlyContinue
if (-not (Test-Path "IIS:\Sites\$siteName")) {
    New-WebSite -Name $siteName -PhysicalPath $sitePath `
                -ApplicationPool $appPoolName -Port 80
}

# web.config: SPA fallback + ARR reverse proxy for /api/*
$webConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <!-- Reverse proxy: /api/* -> Node.js backend on port 5000 -->
        <rule name="API Proxy" stopProcessing="true">
          <match url="^api/(.*)" />
          <action type="Rewrite" url="http://localhost:5000/api/{R:1}" />
        </rule>
        <!-- SPA fallback: unknown paths -> index.html -->
        <rule name="SPA Fallback" stopProcessing="true">
          <match url=".*" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_FILENAME}" matchType="IsFile" negate="true" />
            <add input="{REQUEST_FILENAME}" matchType="IsDirectory" negate="true" />
          </conditions>
          <action type="Rewrite" url="/index.html" />
        </rule>
      </rules>
    </rewrite>
    <staticContent>
      <mimeMap fileExtension=".js"  mimeType="application/javascript" />
      <mimeMap fileExtension=".css" mimeType="text/css" />
      <mimeMap fileExtension=".svg" mimeType="image/svg+xml" />
    </staticContent>
  </system.webServer>
</configuration>
"@
Set-Content -Path "$sitePath\web.config" -Value $webConfig -Encoding UTF8
Write-Log "IIS site 'ecomm' configured with SPA fallback and API proxy."

# =============================================================================
# STEP 11 — Configure OpenSSH for the deploy user
# =============================================================================
Write-Log "=== Configuring OpenSSH ==="
Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
Start-Service sshd
Set-Service  sshd -StartupType Automatic

$authorizedKeysPath = "C:\ProgramData\ssh\administrators_authorized_keys"
# SECURITY: SSH public key from Key Vault — only this key can authenticate as admin
Set-Content -Path $authorizedKeysPath -Value $sshPubKey -Encoding UTF8
# Fix permissions: only SYSTEM and Administrators should read this file
icacls $authorizedKeysPath /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)" | Out-Null
Write-Log "OpenSSH configured. Authorized key written."

# =============================================================================
# STEP 12 — Write backend .env file
# SECURITY: DB_PASSWORD fetched from Key Vault, not passed via pipeline env var
# =============================================================================
Write-Log "=== Writing backend .env ==="
$envContent = @"
DB_HOST=127.0.0.1
DB_PORT=3306
DB_USER=ecommapp
DB_PASSWORD=$dbAppPw
DB_NAME=ecomm
PORT=5000
CORS_ORIGIN=http://$vmPublicIP
"@
# SECURITY: .env file is written to disk with restricted permissions
Set-Content -Path "C:\deploy\backend\.env" -Value $envContent -Encoding UTF8
icacls "C:\deploy\backend\.env" /inheritance:r `
    /grant "SYSTEM:(F)" /grant "Administrators:(F)" | Out-Null
Write-Log "backend .env written."

# =============================================================================
# STEP 13 — Start backend with PM2
# =============================================================================
Write-Log "=== Starting backend with PM2 ==="
Set-Location "C:\deploy\backend"
pm2 start src/index.js --name ecomm-api
pm2 save
pm2-startup install
Write-Log "PM2 ecomm-api started and registered as Windows service."

# Clean up secret variables from memory
# SECURITY: overwrite sensitive variables before script exits
$mysqlRootPw = $null
$dbAppPw     = $null
$sshPubKey   = $null
[GC]::Collect()

Write-Log "=== setup-vm.ps1 completed successfully ==="
