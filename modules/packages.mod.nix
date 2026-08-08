# Packages that carry no configuration; anything with config has its own file.
# The system list reaches every user on every host; the home lists are bundle
# members.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.packages;
  flake.nixosModules.packages =
    { pkgs, ... }:
    {
      unfreePackages = [
        "claude-code"
        "obsidian"
      ];

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
        pkgs.git
      ];
    };

  # The graphical session's utilities and applications.
  flake.homeModules.desktop = self.homeModules.packages-desktop;
  flake.homeModules.packages-desktop =
    { config, pkgs, ... }:
    {
      home.packages = [
        # Elected applications (default-apps.mod.nix); referencing the options
        # installs whatever a host overrides them to.
        config.desktopApps.email
        config.desktopApps.pdfViewer
        config.desktopApps.imageViewer
        config.desktopApps.videoPlayer

        pkgs.brightnessctl
        pkgs.cliphist
        pkgs.hyprpicker
        pkgs.hyprshot
        pkgs.pavucontrol
        pkgs.playerctl
        pkgs.wl-clip-persist
        pkgs.wl-clipboard

        # Installed only; DMS owns selection. home.pointerCursor would
        # generate competing GTK and hyprcursor config.
        pkgs.bibata-cursors

        pkgs.brave
        pkgs.kdePackages.dolphin
        # ark is Dolphin's archive context menu; nothing else installs an icon
        # theme.
        pkgs.kdePackages.ark
        pkgs.kdePackages.breeze-icons
        pkgs.keepassxc
        pkgs.libreoffice
        pkgs.obsidian
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
        pkgs.rust-analyzer
        pkgs.rustc
        pkgs.rustfmt
      ];
    };
}
