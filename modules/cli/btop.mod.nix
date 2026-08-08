# System monitor.
{ self, ... }:
{
  flake.homeModules.default = self.homeModules.btop;
  flake.homeModules.btop = {
    programs.btop = {
      enable = true;
      settings = {
        truecolor = true;
        vim_keys = true;
        rounded_corners = true;
        graph_symbol = "braille";
      };
    };
  };
}
