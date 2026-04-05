# =============================================================================
# outputs.tf — values exported after terraform apply
# =============================================================================

output "vm_public_ip" {
  description = "Public IP address of the Windows Server VM. Use this for SSH, RDP, and browser access."
  value       = azurerm_public_ip.ecomm.ip_address
}

output "key_vault_uri" {
  description = "URI of the Azure Key Vault (e.g. https://kv-ecomm.vault.azure.net/). Used by Get-KeyVaultSecret in setup-vm.ps1."
  value       = azurerm_key_vault.ecomm.vault_uri
  sensitive   = false
}

output "key_vault_name" {
  description = "Name of the Azure Key Vault. Used by the keyvault-secrets GitHub Actions job."
  value       = azurerm_key_vault.ecomm.name
}

output "resource_group_name" {
  description = "Name of the Azure resource group containing all ecomm resources."
  value       = azurerm_resource_group.ecomm.name
}

output "vm_managed_identity_client_id" {
  description = "Client ID of the VM user-assigned managed identity. Used in IMDS token requests inside the VM."
  value       = azurerm_user_assigned_identity.ecomm_vm.client_id
}

output "rdp_connection_hint" {
  description = "How to RDP into the VM. Requires az login and the connect-rdp.ps1 helper script."
  value       = "Run: .\\scripts\\connect-rdp.ps1 -KeyVaultName ${azurerm_key_vault.ecomm.name}"
  sensitive   = false
}
