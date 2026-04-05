# =============================================================================
# main.tf — Azure infrastructure for ecomm (3-tier app on Windows Server 2022)
# Terraform AzureRM >= 3.0 | Auth: OIDC federated credentials
# =============================================================================

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  # Remote state in Azure Blob Storage.
  # Create the storage account + container BEFORE running terraform init.
  # See: docs/manual-steps.md for the az CLI commands.
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "tfstatesa" # override via -backend-config if needed
    container_name       = "tfstate"
    key                  = "ecomm.terraform.tfstate"
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
  # OIDC auth — no client_secret needed.
  # Requires: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID env vars
  # (set in GitHub Actions env block or locally via az login --service-principal)
  use_oidc        = true
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# -----------------------------------------------------------------------------
# Data sources
# -----------------------------------------------------------------------------
data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# Resource Group
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "ecomm" {
  name     = var.resource_group_name
  location = var.location

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "ecomm" {
  name                = "vnet-ecomm"
  location            = azurerm_resource_group.ecomm.location
  resource_group_name = azurerm_resource_group.ecomm.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.common_tags
}

resource "azurerm_subnet" "ecomm" {
  name                 = "snet-ecomm"
  resource_group_name  = azurerm_resource_group.ecomm.name
  virtual_network_name = azurerm_virtual_network.ecomm.name
  address_prefixes     = ["10.0.1.0/24"]
}

# -----------------------------------------------------------------------------
# Network Security Group
# -----------------------------------------------------------------------------
resource "azurerm_network_security_group" "ecomm" {
  name                = "nsg-ecomm"
  location            = azurerm_resource_group.ecomm.location
  resource_group_name = azurerm_resource_group.ecomm.name
  tags                = local.common_tags

  # HTTP — open to internet
  security_rule {
    name                       = "allow-http"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # HTTPS — open to internet
  security_rule {
    name                       = "allow-https"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # RDP — restricted to deployer IP only
  # SECURITY: limits RDP exposure to a single trusted IP
  security_rule {
    name                       = "allow-rdp"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.allowed_rdp_source_ip
    destination_address_prefix = "*"
  }

  # SSH / OpenSSH — restricted to deployer IP only
  # SECURITY: limits SSH exposure to a single trusted IP (used by CI/CD deploy job)
  security_rule {
    name                       = "allow-ssh"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_source_ip
    destination_address_prefix = "*"
  }

  # MySQL 3306 — NO inbound rule = denied by default NSG behaviour.
  # Backend connects to 127.0.0.1:3306 only.
}

resource "azurerm_subnet_network_security_group_association" "ecomm" {
  subnet_id                 = azurerm_subnet.ecomm.id
  network_security_group_id = azurerm_network_security_group.ecomm.id
}

# -----------------------------------------------------------------------------
# Public IP
# -----------------------------------------------------------------------------
resource "azurerm_public_ip" "ecomm" {
  name                = "pip-ecomm"
  location            = azurerm_resource_group.ecomm.location
  resource_group_name = azurerm_resource_group.ecomm.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# Network Interface
# -----------------------------------------------------------------------------
resource "azurerm_network_interface" "ecomm" {
  name                = "nic-ecomm"
  location            = azurerm_resource_group.ecomm.location
  resource_group_name = azurerm_resource_group.ecomm.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.ecomm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ecomm.id
  }
}

# -----------------------------------------------------------------------------
# User-Assigned Managed Identity (Key Vault access for the VM)
# -----------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "ecomm_vm" {
  name                = "id-ecomm-vm"
  location            = azurerm_resource_group.ecomm.location
  resource_group_name = azurerm_resource_group.ecomm.name
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# Key Vault
# Must be created BEFORE the VM so setup-vm.ps1 can read secrets via IMDS.
# -----------------------------------------------------------------------------
resource "azurerm_key_vault" "ecomm" {
  name                        = var.key_vault_name
  location                    = azurerm_resource_group.ecomm.location
  resource_group_name         = azurerm_resource_group.ecomm.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false # set true for production
  enable_rbac_authorization   = true  # use RBAC not access policies
  tags                        = local.common_tags
}

# Grant the Terraform runner (CI/CD service principal) Key Vault Secrets Officer
# so it can create secrets in the keyvault-secrets pipeline job.
# SECURITY: scoped to this Key Vault only
resource "azurerm_role_assignment" "tf_kv_officer" {
  scope                = azurerm_key_vault.ecomm.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Grant the VM managed identity Key Vault Secrets User
# so setup-vm.ps1 and the running app can read secrets via IMDS.
# SECURITY: read-only access; cannot create or delete secrets
resource "azurerm_role_assignment" "vm_kv_user" {
  scope                = azurerm_key_vault.ecomm.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.ecomm_vm.principal_id
  depends_on           = [azurerm_key_vault.ecomm]
}

# -----------------------------------------------------------------------------
# Key Vault Secrets — populated here as placeholders; real values are pushed
# by the `keyvault-secrets` GitHub Actions job after infra is provisioned.
# SECURITY: marked sensitive so values never appear in Terraform plan output.
# -----------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "mysql_root_password" {
  name         = "mysql-root-password"
  value        = var.mysql_root_password # SECURITY: MySQL root credential
  key_vault_id = azurerm_key_vault.ecomm.id
  depends_on   = [azurerm_role_assignment.tf_kv_officer]
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = var.db_password # SECURITY: app-level MySQL user credential
  key_vault_id = azurerm_key_vault.ecomm.id
  depends_on   = [azurerm_role_assignment.tf_kv_officer]
}

resource "azurerm_key_vault_secret" "vm_admin_password" {
  name         = "vm-admin-password"
  value        = var.vm_admin_password # SECURITY: Windows administrator password
  key_vault_id = azurerm_key_vault.ecomm.id
  depends_on   = [azurerm_role_assignment.tf_kv_officer]
}

resource "azurerm_key_vault_secret" "vm_ssh_public_key" {
  name         = "vm-ssh-public-key"
  value        = var.vm_ssh_public_key # SECURITY: SSH public key for deploy user
  key_vault_id = azurerm_key_vault.ecomm.id
  depends_on   = [azurerm_role_assignment.tf_kv_officer]
}

# Store admin username in Key Vault so connect-rdp.ps1 can retrieve it without
# hardcoding it locally. Not sensitive but kept alongside the password for convenience.
resource "azurerm_key_vault_secret" "vm_admin_username" {
  name         = "vm-admin-username"
  value        = var.vm_admin_username
  key_vault_id = azurerm_key_vault.ecomm.id
  depends_on   = [azurerm_role_assignment.tf_kv_officer]
}

# -----------------------------------------------------------------------------
# Windows Virtual Machine
# -----------------------------------------------------------------------------
resource "azurerm_windows_virtual_machine" "ecomm" {
  name                = "vm-ecomm"
  location            = azurerm_resource_group.ecomm.location
  resource_group_name = azurerm_resource_group.ecomm.name
  size                = var.vm_size
  admin_username      = var.vm_admin_username
  admin_password      = var.vm_admin_password # SECURITY: stored in Key Vault above

  network_interface_ids = [azurerm_network_interface.ecomm.id]
  tags                  = local.common_tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-Datacenter"
    version   = "latest"
  }

  # Attach managed identity so the VM can read Key Vault secrets via IMDS
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ecomm_vm.id]
  }

  # Ensure Key Vault secrets exist before VM boots
  depends_on = [
    azurerm_key_vault_secret.mysql_root_password,
    azurerm_key_vault_secret.db_password,
    azurerm_key_vault_secret.vm_ssh_public_key,
  ]
}

# -----------------------------------------------------------------------------
# VM Custom Script Extension — one-time bootstrap
# setup-vm.ps1 is uploaded to blob storage by the CI/CD pipeline before
# terraform apply, and its SAS URL is passed via var.setup_script_url.
# Using protected_settings keeps the SAS token out of Azure activity logs.
# -----------------------------------------------------------------------------
locals {
  common_tags = {
    project     = "ecomm"
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "azurerm_virtual_machine_extension" "setup" {
  name                 = "setup-vm"
  virtual_machine_id   = azurerm_windows_virtual_machine.ecomm.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Bypass -File setup-vm.ps1 -KeyVaultName ${azurerm_key_vault.ecomm.name}"
  })

  # fileUris in protected_settings so the SAS token is never written to
  # Azure portal activity logs or Terraform plan output.
  # SECURITY: SAS URL contains a time-limited read-only token
  protected_settings = jsonencode({
    fileUris = [var.setup_script_url]
  })

  tags       = local.common_tags
  depends_on = [azurerm_windows_virtual_machine.ecomm]
}
