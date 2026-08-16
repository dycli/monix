# The remote coding-agent seat: Paseo's daemon drives an existing user's
# authenticated claude/codex/opencode CLIs, reachable from phone/web clients
# over the tailnet. Agents inherit that user's privilege boundary.
{ self, inputs, ... }:
{
  flake.nixosModules.lab = self.nixosModules.paseo;
  flake.nixosModules.paseo =
    { pkgs, lib, ... }:
    {
      imports = lib.lists.singleton inputs.paseo.nixosModules.paseo;

      services.paseo = {
        enable = true;
        # node-pty ships per-platform prebuilt binaries, but upstream's install
        # trace copies them from a hardcoded hoisted path while npm nests
        # node-pty under packages/server — so its linux-x64 prebuild never
        # reaches the output and the daemon crashes on first terminal spawn.
        # Copy the linux-x64 prebuild beside every node-pty copy;
        # autoPatchelfHook (already in the derivation) fixes the ELF for NixOS.
        package = (inputs.paseo.packages.${pkgs.stdenv.hostPlatform.system}.paseo).overrideAttrs (old: {
          postInstall = (old.postInstall or "") + ''
            prebuild=$(find "$PWD" -type d -path '*/node-pty/prebuilds/linux-x64' -print -quit)
            [ -n "$prebuild" ] || {
              echo "node-pty linux-x64 prebuild not found in build tree" >&2
              exit 1
            }
            find "$out" -type d -name node-pty | while read -r d; do
              mkdir -p "$d/prebuilds"
              cp -a "$prebuild" "$d/prebuilds/"
            done
          '';
        });

        # inheritUserEnvironment (default for a non-paseo user) puts that
        # account's profile on PATH, so providers resolve from its installs.
        # Water keeps the locked bridge seat; another host can override this.
        user = lib.modules.mkDefault "bridge";
        group = lib.modules.mkDefault "bridge";

        # bazarr owns 6767 (Paseo's default). tailscale0 is a trusted firewall
        # interface, so binding broadly with the public firewall closed leaves
        # the daemon reachable over the tailnet only.
        port = 6768;
        listenAddress = "0.0.0.0";
        openFirewall = false;

        # Direct connections only; no hosted relay.
        relay.enable = false;

        # Phone/web clients reach it by MagicDNS name; loopback and IPs are
        # always allowed regardless.
        hostnames = lib.lists.singleton ".olm-hen.ts.net";
      };
    };
}
