subscription_id        = "76736ba2-9670-4b91-81d2-38a0275ded46"
tenant_id              = "1b0eebeb-0722-47f9-8d4f-b8ed659bb53c"
client_id              = "3abb3608-c205-4047-80d5-c9407c8da8da"
publisher_email        = "teejay4125@outlook.com"
current_user_object_id = "7d131e76-7ba6-4baa-9a19-fea5d028d760"
environment            = "dev"
location               = "uksouth"
project                = "inframonitor"
create_apim            = false

# keyvault_allowed_ip_ranges / cosmos_allowed_ip_ranges intentionally omitted (default []).
# CI now runs on a self-hosted runner inside apps-subnet, reaching Key Vault/Cosmos DB via their
# private endpoints - no public IP exception needed there anymore. If you need to run
# terraform apply from your own laptop against these firewalled resources, either add your IP
# temporarily (-var 'keyvault_allowed_ip_ranges=["<your-ip>/32"]' -var 'cosmos_allowed_ip_ranges=["<your-ip>/32"]')
# or run it from inside the VNet (e.g. via the runner VM or a bastion-connected host).

# Public key only (not the private key) - safe to commit, but fill in your own before applying.
# Generate a dedicated keypair for this VM, e.g.: ssh-keygen -t ed25519 -f ./runner_key -N ""
runner_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCsclyQyAvGejmJI9KcbDqfOjbz/m/KIS+mF3BcE1mZ3U+4KhaoIpAao6PA27ixmkUVFv7HiU5IdZhPbe/3U8zWWHafaES+9cZl/yjQoR0dK+L+XpwksMTds5nsnEVJeV2pmB3N/0f8xbMeSFN+CjPqdd5J+z+fuE2pHAgAVGBcqRwKVMvG5os3iYbeXtYhmo4pK75bSPdrlViy+JCvsb4e2VqLriHitfHcJUKNwWSlNgZdbEY68YeCsdkMySxenJNWSRiTdInNfKindZtA0weG/rCjqU+1khwRg1gDags/TjSW31CjJMscoqgSdbOw+wz/0ARmPqjbyhJO682zFj3WIROg0ZCJ0j26zndsPuGXaOb4L0YyadQCCHQ24Yqc9bcYW2SmV9HXWMat64yU/kFo110Z5OXHl1dIa5olW7pRnpgnZ9xg12jTNJkQ96+6Ph1IN50u3tZb3JMt6GafuHbv5JeEMhv97CIdwoAsyHHiLdMajnYko2e0XGe6RNGoi3crYtaNyU6qyQ/HjAQxK6xLLHjEuxO5aS0PXflc9lU5AXElcLI1m8bbrzY+NqnLpOc4wJ8SIe5kL+6uR8QZPy0QUbpMffZvLa/pMm8lqKaHP0jvQzCAXs5rRO9h3UwykBeOcs+zO5uSK+b0hT+qOyCrnEw91G3Zy+wLg9KZl5Irmw== github-runner"

github_org  = "teejayade2244"
github_repo = "Cloud-Infrastructure-Monitoring-Alerting-Platform"
