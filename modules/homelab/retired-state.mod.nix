# State of services this configuration no longer declares. Each folder is
# archived to the NAS, where the nightly backup carries it, checked to read
# back, then deleted from the OS disk. Drop this module once Water's /var/lib
# holds none of the folders below.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.retired-state;
  flake.nixosModules.retired-state =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) optionals singleton;
      inherit (lib.options) mkEnableOption;
      inherit (lib.strings) escapeShellArgs;

      # Relative to /var/lib. A symlink is archived with its target.
      # The old household, retired with A2A (Dylan's yes, 2026-11-13).
      approved = singleton "yeoman-household";
      # The retired assistants and older setups, held until Dylan agrees to
      # their removal; retiredState.others turns them on.
      others = [
        "alerts"
        "amnesia"
        "azula"
        "raava"
        "remy"
        "sokka"
        "newsbot"
        "news-keys"
        "budgetbot"
        "curtisbot"
        "fleet-log-stream"
        "nut-alerts"
        "yeoman-sites"
        "yeoman-x"
        "homepage-dashboard"
        "actual"
        "tennis"
        "lxc"
        "waydroid"
      ];
      retired = approved ++ optionals config.retiredState.others others;
      archive = "/srv/storage/archive/retired-state";

      retire = pkgs.writeShellApplication {
        name = "retire-state";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gnutar
          pkgs.zstd
          pkgs.util-linux
        ];
        text = ''
          mountpoint -q /srv/storage
          install -d -m 0700 ${archive}
          retired=(${escapeShellArgs retired})
          for name in "''${retired[@]}"; do
            path=/var/lib/$name
            [[ -e $path || -L $path ]] || continue
            members=("$name")
            if [[ -L $path ]]; then
              target=$(readlink "$path")
              [[ -e /var/lib/$target ]] && members+=("$target")
            fi
            out=${archive}/$name.tar.zst
            tar --zstd --numeric-owner --xattrs --acls -C /var/lib -cf "$out.tmp" "''${members[@]}"
            # Every file must read back whole before anything is deleted.
            tar --zstd -C /var/lib --compare -f "$out.tmp" > /dev/null
            mv "$out.tmp" "$out"
            sync -f "$out"
            for member in "''${members[@]}"; do rm -rf --one-file-system "/var/lib/$member"; done
            echo "archived and removed /var/lib/$name"
          done
        '';
      };
    in
    {
      options.retiredState.others = mkEnableOption "archiving and removing the retired assistants' and older setups' state, beyond the approved folders";

      config.systemd.services.retired-state = {
        description = "Archive retired services' state to the NAS, then remove it";
        wantedBy = singleton "multi-user.target";
        unitConfig.RequiresMountsFor = "/srv/storage";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.meta.getExe retire;
          UMask = "0077";
          Nice = 10;
          IOSchedulingClass = "idle";
        };
      };
    };
}
