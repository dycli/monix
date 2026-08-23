# System monitor.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.btop;
  flake.homeModules.btop = {
    programs.btop = {
      enable = true;
      settings = {
        cpu_sensor = "k10temp";
        update_ms = 100;
        truecolor = true;
        vim_keys = true;
        rounded_corners = true;
        graph_symbol = "braille";
      };
    };
  };
}
