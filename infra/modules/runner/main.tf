resource "azurerm_network_interface" "runner" {
  name                = "${var.project}-runner-nic-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.runner_subnet_id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id - the runner is outbound-only (to github.com), reached for
    # management via Bastion or another VM in the VNet, never directly from the internet.
  }
}

resource "azurerm_linux_virtual_machine" "runner" {
  name                = "${var.project}-runner-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = "Standard_D2lds_v6"
  admin_username      = "runneradmin"
  network_interface_ids = [
    azurerm_network_interface.runner.id,
  ]
  tags = var.tags

  disable_password_authentication = true

  admin_ssh_key {
    username   = "runneradmin"
    public_key = var.runner_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_virtual_machine_extension" "bootstrap_runner" {
  name                 = "bootstrap-runner"
  virtual_machine_id   = azurerm_linux_virtual_machine.runner.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"

  settings = jsonencode({
    script = base64encode(file("${path.module}/bootstrap.sh"))
  })
}

resource "azurerm_role_assignment" "runner_contributor" {
  scope                = var.resource_group_id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_virtual_machine.runner.identity[0].principal_id
}
