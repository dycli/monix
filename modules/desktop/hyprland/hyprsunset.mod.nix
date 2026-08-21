# Night light. hyprsunset applies temperature through Hyprland's CTM
# protocol, composing with the monitor rules' ICC profile; wlr-gamma
# clients would replace the gamma table the ICC occupies.
{ self, ... }:
{
  flake.homeModules.hyprland = self.homeModules.hyprsunset;
  flake.homeModules.hyprsunset =
    { lib, pkgs, ... }:
    let
      kestrelHyprsunset = pkgs.writeShellApplication {
        name = "kestrel-hyprsunset";
        runtimeInputs = [ pkgs.hyprsunset ];
        text = ''
          state_root="''${XDG_STATE_HOME:-$HOME/.local/state}"
          temperature_path="$state_root/kestrel/night-light-temperature"
          temperature=5500

          if [[ -r "$temperature_path" ]]; then
            candidate="$(<"$temperature_path")"
            if [[ "$candidate" =~ ^[0-9]+$ ]] \
              && (( candidate >= 2500 && candidate <= 6500 )); then
              temperature="$candidate"
            fi
          fi

          exec hyprsunset --temperature "$temperature"
        '';
      };
    in
    {
      services.hyprsunset.enable = true;
      systemd.user.services.hyprsunset.Service.ExecStart =
        lib.mkForce "${kestrelHyprsunset}/bin/kestrel-hyprsunset";
    };
}
