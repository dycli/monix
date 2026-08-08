# Neovim as NvChad, with runtime tools injected into the nvim wrapper rather
# than the global PATH. Plain pkgs.neovim collides with that wrapper and must
# not be installed. Both editors pin shell to /bin/sh, since their POSIX `-c`
# shell-outs fail under nushell with "E79: Cannot expand wildcards".
{ self, inputs, ... }:
{
  flake.homeModules.default = self.homeModules.editors;
  flake.homeModules.editors =
    { lib, pkgs, ... }:
    {
      imports = lib.lists.singleton inputs.nix4nvchad.homeManagerModules.default;

      programs.nvchad = {
        enable = true;

        # Visible inside the nvim wrapper only, not on the user's PATH.
        extraPackages = [
          pkgs.lazygit
        ];

        extraConfig = ''
          vim.o.shell = "/bin/sh"
        '';
      };

      home.file.".vimrc".text = ''
        set shell=/bin/sh
      '';

      # Overrides the system-wide EDITOR=vim, nvim existing only in this
      # user's profile.
      home.sessionVariables.EDITOR = "nvim";
    };
}
