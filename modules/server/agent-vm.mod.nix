# Agent-fleet worker guests (Phase 2, step 2 — one worker, manual lifecycle).
# See docs/phase2-agent-vm.md §4. Each worker is a minimal, purpose-built
# NixOS microVM — deliberately NOT composed from self.nixosModules (workers
# are not fleet hosts; no tailnet, no monorepo, no host secrets, by absence).
# Claude Code runs fully-permissioned inside; containment is the host's
# default-deny egress, not anything the guest promises: the guest has no
# default route and no DNS, so the squid allowlist proxy on the bridge IP is
# structurally the only way out.
#
# Ephemerality: the guest root is tmpfs (microvm.nix default) and the nix
# store is the host's, read-only over virtiofs. Only the two volume images
# (store overlay + /workspace scratch) persist across restarts — the
# wipe-on-start hook is step 4 of the plan, not yet installed.
#
# Secrets are STUBBED at this step (plan §8 step 2): no credentialFiles yet,
# so Claude Code inside the guest has no API key until step 3 lands.
{ self, ... }:
{
  flake.nixosModules.agent-guests =
    { config, lib, ... }:
    let
      inherit (lib.modules) mkIf;
      inherit (lib.lists) singleton;
      inherit (lib.strings) fixedWidthString;

      cfg = config.agentFleet;

      hostAddr = "10.100.0.1";
      proxyUrl = "http://${hostAddr}:3128";

      # One worker class per repo (plan §6); `index` numbers workers within
      # the fleet and derives both the bridge address (10.100.0.10+index) and
      # a locally-administered MAC. The decimal index doubles as the MAC's
      # last octet — unique for index <= 99, which is plenty.
      mkAgentGuest =
        {
          name,
          index,
          vcpu ? 8,
          mem ? 8192, # MiB, static — no ballooning (plan invariant 9)
        }:
        let
          addr = "10.100.0.${toString (10 + index)}";
          mac = "02:00:00:00:00:${fixedWidthString 2 "0" (toString index)}";
        in
        {
          # Phase 2 is manual lifecycle: the cockpit starts/stops
          # microvm@<name> by hand; nothing autostarts at boot.
          autostart = false;

          config =
            { pkgs, ... }:
            {
              microvm = {
                hypervisor = "cloud-hypervisor";
                inherit vcpu mem;

                interfaces = singleton {
                  type = "tap";
                  id = "vm-${name}"; # enslaved to br-agents by the networkd vm-* match
                  inherit mac;
                };

                # The host's store, read-only. Note this exposes the ENTIRE
                # host store to the guest — never put secrets in the store.
                shares = singleton {
                  proto = "virtiofs";
                  tag = "ro-store";
                  source = "/nix/store";
                  mountPoint = "/nix/.ro-store";
                };

                # Writable overlay so `nix build` works inside the guest.
                # Backed by a volume; contents are disposable by design (the
                # guest's nix db forgets built paths on restart anyway).
                writableStoreOverlay = "/nix/.rw-store";
                volumes = [
                  {
                    image = "nix-overlay.img";
                    mountPoint = "/nix/.rw-store";
                    size = 8192;
                  }
                  {
                    image = "workspace.img";
                    mountPoint = "/workspace";
                    size = 20480;
                  }
                ];
              };

              # NETWORKING — static address on the host-only bridge subnet,
              # deliberately NO gateway and NO DNS: the guest cannot route or
              # resolve anything. Squid does all resolving on its behalf.
              networking.useNetworkd = true;
              networking.useDHCP = false;
              systemd.network.networks."20-lan" = {
                matchConfig.MACAddress = mac;
                address = singleton "${addr}/24";
              };

              # Everything HTTP(S) goes through the proxy. networking.proxy
              # covers the lowercase env vars plus nix-daemon; Claude Code and
              # Codex (Node) want the uppercase forms, set explicitly.
              networking.proxy.default = proxyUrl;
              environment.variables = {
                HTTP_PROXY = proxyUrl;
                HTTPS_PROXY = proxyUrl;
                NO_PROXY = "127.0.0.1,localhost";
              };

              environment.systemPackages = [
                pkgs.claude-code
                pkgs.codex
                pkgs.git
                pkgs.gh
                pkgs.ripgrep
                pkgs.fd
                pkgs.jq
                pkgs.curl
                pkgs.gnumake
                pkgs.gcc
              ];

              nix.settings.experimental-features = [
                "flakes"
                "nix-command"
              ];
              # Substituters stay at the default cache.nixos.org — the only
              # cache on the egress allowlist (.nixos.org).

              # The sole account. No wheel, no sudo; it owns /workspace and
              # nothing else. Keyed to the admin keys for Phase 2 (the human
              # cockpit is the dispatcher; a dedicated dispatch keypair
              # arrives with Phase 3).
              users.users.agent = {
                isNormalUser = true;
                description = "fleet worker";
                openssh.authorizedKeys.keys = self.keys-admin;
              };
              systemd.tmpfiles.rules = singleton "d /workspace 0755 agent users -";

              services.openssh = {
                enable = true;
                settings.PermitRootLogin = "no";
                settings.PasswordAuthentication = false;
              };

              # Root autologin on the serial console: reaching the console at
              # all requires host-root (the microvm@ unit's PTY), and guest
              # containment never rests on in-guest auth. Keeps §7
              # verification and debugging one `microvm -s <name>` away.
              services.getty.autologinUser = "root";

              system.stateVersion = "26.05";
            };
        };
    in
    {
      config = mkIf cfg.enable {
        microvm.vms.lfish-0 = mkAgentGuest {
          name = "lfish-0";
          index = 1;
        };

        # microvm.nix has no slice option; standard unit override so the
        # worker counts against the fleet's 48G/agents.slice fence.
        systemd.services."microvm@lfish-0".serviceConfig.Slice = "agents.slice";
      };
    };
}
