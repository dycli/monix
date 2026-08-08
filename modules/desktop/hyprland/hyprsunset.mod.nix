# Night light. hyprsunset applies temperature through Hyprland's CTM
# protocol, composing with the monitor rules' ICC profile; wlr-gamma
# clients would replace the gamma table the ICC occupies.
{ self, ... }:
{
  flake.homeModules.hyprland = self.homeModules.hyprsunset;
  flake.homeModules.hyprsunset = {
    services.hyprsunset = {
      enable = true;
      settings.profile = [
        {
          time = "7:00";
          identity = true;
        }
        {
          time = "21:00";
          temperature = 5500;
        }
      ];
    };
  };
}
