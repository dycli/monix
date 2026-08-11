# Neovim as NvChad, with runtime tools injected into the nvim wrapper rather
# than the global PATH. Plain pkgs.neovim collides with that wrapper and must
# not be installed. Both editors pin shell to /bin/sh, since their POSIX `-c`
# shell-outs fail under nushell with "E79: Cannot expand wildcards".
{ self, inputs, ... }:
{
  # The editor stack drags a build toolchain along (treesitter compiles its
  # grammars, the LSPs ride node); servers opt out and keep system vim.
  flake.nixosModules.default = self.nixosModules.editors;
  flake.nixosModules.editors =
    { lib, ... }:
    {
      options.editors.enable = lib.options.mkEnableOption "the NvChad editor stack" // {
        default = true;
      };
    };

  flake.homeModules.default = self.homeModules.editors;
  flake.homeModules.editors =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    {
      imports = lib.lists.singleton inputs.nix4nvchad.homeManagerModules.default;

      config = lib.modules.mkIf osConfig.editors.enable {
        programs.nvchad = {
          enable = true;

          # Visible inside the nvim wrapper only, not on the user's PATH.
          extraPackages = lib.lists.singleton pkgs.lazygit;

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
    };
}
