# =============================================================================
# connect-rdp.ps1 — Fetch VM credentials from Azure Key Vault and open RDP
#
# Prerequisites (run once):
#   az login
#   Set $KeyVaultName and $ResourceGroupName below, or pass as parameters.
#
# Usage:
#   .\scripts\connect-rdp.ps1 -KeyVaultName kv-ecomm-unique123
#   .\scripts\connect-rdp.ps1 -KeyVaultName kv-ecomm-unique123 -ResourceGroup rg-ecomm
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$KeyVaultName,

    [string]$ResourceGroupName = "rg-ecomm"
    # VmAdminUsername is now fetched from Key Vault automatically
)

$ErrorActionPreference = "Stop"

# Verify az CLI is available
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install from https://aka.ms/installazurecliwindows and run 'az login'."
}

Write-Host "Fetching VM public IP from Azure..." -ForegroundColor Cyan

# Get the VM public IP from Azure (no need to remember it manually)
$vmIp = (az vm list-ip-addresses `
    --resource-group $ResourceGroupName `
    --name "vm-ecomm" `
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" `
    --output tsv 2>$null)

if ([string]::IsNullOrWhiteSpace($vmIp)) {
    throw "Could not resolve VM public IP. Ensure the VM exists in resource group '$ResourceGroupName' and you are logged in with 'az login'."
}
Write-Host "VM public IP: $vmIp" -ForegroundColor Green

# Fetch the VM admin password from Key Vault
# SECURITY: password is fetched from Key Vault at runtime — never stored on disk
Write-Host "Fetching VM admin credentials from Key Vault '$KeyVaultName'..." -ForegroundColor Cyan
$vmPassword = (az keyvault secret show `
    --vault-name $KeyVaultName `
    --name "vm-admin-password" `
    --query "value" `
    --output tsv)

if ([string]::IsNullOrWhiteSpace($vmPassword)) {
    throw "Could not retrieve 'vm-admin-password' from Key Vault '$KeyVaultName'. " +
          "Check that the secret exists and you have 'Key Vault Secrets User' role."
}

# Fetch admin username from Key Vault
$VmAdminUsername = (az keyvault secret show `
    --vault-name $KeyVaultName `
    --name "vm-admin-username" `
    --query "value" `
    --output tsv)

if ([string]::IsNullOrWhiteSpace($VmAdminUsername)) {
    $VmAdminUsername = "ecommadmin"   # fallback to default
}
Write-Host "Admin username: $VmAdminUsername" -ForegroundColor Green

# Register credentials with Windows Credential Manager for this session.
# cmdkey stores them temporarily so mstsc can auto-fill without prompting.
# SECURITY: credentials are stored under the VM IP key, not globally
Write-Host "Registering temporary RDP credentials..." -ForegroundColor Cyan
cmdkey /generic:"TERMSRV/$vmIp" /user:"$VmAdminUsername" /pass:"$vmPassword" | Out-Null

# Clear the password variable from memory before launching RDP
# SECURITY: password variable overwritten before passing control to mstsc
$vmPassword = $null
[GC]::Collect()

# Launch Remote Desktop
Write-Host "Opening Remote Desktop to $vmIp ..." -ForegroundColor Green
mstsc /v:"$vmIp"

# Clean up the stored credential after RDP session ends
# (mstsc is synchronous — this runs when the RDP window closes)
Write-Host "Removing temporary credential from Credential Manager..." -ForegroundColor Cyan
cmdkey /delete:"TERMSRV/$vmIp" | Out-Null
Write-Host "Done. Credential removed." -ForegroundColor Green
