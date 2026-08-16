# Packages that carry no configuration; anything with config has its own file.
# The system list reaches every user on every host; the home lists are bundle
# members.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.packages;
  flake.nixosModules.packages =
    { pkgs, ... }:
    {
      # nvim exists only in the primary user's profile, so a system-wide
      # EDITOR=nvim would dangle for root and service users.
      environment.variables.EDITOR = "vim";

      # nano's own module enables it independently of defaultPackages.
      environment.defaultPackages = [ ];
      programs.nano.enable = false;

      environment.systemPackages = [
        # neovim is absent: NvChad's wrapper provides it per-user and a plain
        # install collides.
        pkgs.vim

        pkgs.eza
        pkgs.fd
        pkgs.fzf
        pkgs.htop
        pkgs.microfetch
        pkgs.nushell
        pkgs.ripgrep
        pkgs.tmux
        pkgs.tree

        # NETWORK
        pkgs.dig
        pkgs.traceroute
        pkgs.wget
        pkgs.rsync

        pkgs.strace

        # ARCHIVES
        pkgs.p7zip
        pkgs.unzip
        pkgs.zip

        # Also in the home concern; rebuilds need git in root's PATH.
        # Minimal build: the perl/python porcelain is dead weight fleet-wide.
        pkgs.gitMinimal
      ];
    };

  # Each unfree name travels with the bundle that installs the package.
  flake.nixosModules.desktop =
    { lib, ... }:
    {
      unfreePackages = lib.lists.singleton "obsidian";
    };
  flake.nixosModules.dev =
    { lib, ... }:
    {
      unfreePackages = lib.lists.singleton "claude-code";
    };

  # The graphical session's utilities and applications.
  flake.homeModules.desktop = self.homeModules.packages-desktop;
  flake.homeModules.packages-desktop =
    { config, pkgs, ... }:
    {
      home.packages = [
        # Elected applications (default-apps.mod.nix); referencing the options
        # installs whatever a host overrides them to.
        config.desktopApps.email.package
        config.desktopApps.pdfViewer.package
        config.desktopApps.imageViewer.package
        config.desktopApps.videoPlayer.package

        pkgs.brightnessctl
        pkgs.cliphist
        pkgs.hyprpicker
        pkgs.hyprshot
        pkgs.pavucontrol
        pkgs.playerctl
        pkgs.wl-clip-persist
        pkgs.wl-clipboard

        pkgs.brave
        pkgs.kdePackages.dolphin
        # ark is Dolphin's archive context menu; nothing else installs an icon
        # theme.
        pkgs.kdePackages.ark
        pkgs.kdePackages.breeze-icons
        pkgs.keepassxc
        pkgs.libreoffice
        pkgs.obsidian
        pkgs.element-desktop
        pkgs.signal-desktop
      ];
    };

  # Authoring and build tools.
  flake.homeModules.dev = self.homeModules.packages-dev-extras;
  flake.homeModules.packages-dev-extras =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.cargo
        pkgs.claude-code
        pkgs.clippy
        pkgs.codex
        pkgs.gcc
        pkgs.opencode
        pkgs.hugo
        # The codex plugin's hooks invoke node directly.
        pkgs.nodejs
        pkgs.nixd
        pkgs.rust-analyzer
        pkgs.rustc
        pkgs.rustfmt
      ];
    };
}
