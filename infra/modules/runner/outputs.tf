# After `terraform apply` creates the VM and the bootstrap extension finishes installing
# Azure CLI / Terraform / the runner binary, the runner still isn't registered with GitHub -
# that has to happen interactively, once, from inside the VM:
#
# 1. Reach the VM (it has no public IP): via Azure Bastion, or by SSHing through another
#    VM/jump host already in the VNet:
#      az network bastion ssh --name <bastion-name> --resource-group inframonitor-rg-dev \
#        --target-resource-id <runner_vm_id output below> --auth-type ssh-key \
#        --username runneradmin --ssh-key ~/.ssh/<your-private-key>
#
# 2. Get a registration token for this repo (requires repo admin access):
#      - Via the GitHub UI: Settings -> Actions -> Runners -> New self-hosted runner
#        (copy the token shown in the ./config.sh command it gives you), or
#      - Via the API: gh api -X POST \
#          repos/teejayade2244/Cloud-Infrastructure-Monitoring-Alerting-Platform/actions/runners/registration-token \
#          --jq .token
#
# 3. On the VM, as the `runner` user:
#      sudo -iu runner
#      cd /home/runner/actions-runner
#      ./config.sh --url https://github.com/teejayade2244/Cloud-Infrastructure-Monitoring-Alerting-Platform \
#        --token <TOKEN_FROM_STEP_2> \
#        --labels self-hosted,azure,uksouth \
#        --unattended
#
# 4. Install and start it as a service so it survives reboots (as root, back in your own session):
#      cd /home/runner/actions-runner
#      sudo ./svc.sh install runner
#      sudo ./svc.sh start
#
# Registration tokens expire after about an hour - if you don't get to step 3 in time, just
# generate a fresh one from step 2 and retry.

output "runner_vm_id" {
  value = azurerm_linux_virtual_machine.runner.id
}

output "runner_vm_name" {
  value = azurerm_linux_virtual_machine.runner.name
}

output "runner_private_ip" {
  value = azurerm_network_interface.runner.private_ip_address
}

output "runner_principal_id" {
  value = azurerm_linux_virtual_machine.runner.identity[0].principal_id
}
