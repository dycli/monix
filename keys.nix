# SSH public keys used both for `agenix` secret encryption and for SSH access.
#
#   Host keys  - on each machine run `cat /etc/ssh/ssh_host_ed25519_key.pub`.
#                On a brand-new machine, generate them first with `ssh-keygen -A`,
#                add the key here, then `agenix -r` to rekey existing secrets.
#   Admin keys - your personal public key(s), e.g. `cat ~/.ssh/id_ed25519.pub`.
#
# This file is the single source of truth for keys: `secrets.nix` imports it
# for the agenix CLI, and `lib.ship.keys` carries it into the flake modules.
{
  hosts = {
    water = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINLRVD/zQrWUetJ3VxVJtZ6Zc6wOck05M9l0opF/Emb8 water";
    earth = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN0HL6IH1F5hiNKQ58mIPozF4ov20BfZB4lT/cA6B8Ik earth";
    fire = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPmWR7aIiXX7euvuo4K21GL2X5WHhWVEDas5ZqbFHa1f fire";
    air = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIYqKhV4EHuOMV4WLDjcgEAzgzKQLJ+P6Dzozxa4QTYY air";
  };

  admin = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF7/0+EtR35ZsgmHq0IXNY5gQ1SlTUGSRz+P38qGfn0F dylan@dylandavid.com"
  ];
}
