# Neovim is NvChad via nix4nvchad's home-manager module, with runtime
# tools injected into the nvim wrapper rather than the global PATH. Plain
# pkgs.neovim collides with that wrapper and must not be installed.
#
# Both editors pin shell to /bin/sh, since their POSIX `-c` shell-outs
# fail under nushell with "E79: Cannot expand wildcards".
{ inputs, ... }:
{
  flake.homeModules.editors =
    { pkgs, ... }:
    {
      imports = [ inputs.nix4nvchad.homeManagerModules.default ];

      programs.nvchad = {
        enable = true;

        # LSP servers/formatters go here as they're adopted (e.g. nil,
        # lua-language-server) — visible only inside the nvim wrapper.
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

      # Overrides the system-wide EDITOR=vim (packages.mod.nix): nvim exists
      # in this user's profile. Reaches interactive logins via the HM bash
      # init (interactive-shell.mod.nix); the desktop session sets the same
      # in hyprland.mod.nix's env block.
      home.sessionVariables.EDITOR = "nvim";
    };
}
