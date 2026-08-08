# Packages that carry no configuration; anything with config has its own
# file.
#
# The system list reaches root and every user on every host. The home
# lists are bundle members: hosts that import their bundle get them.
{ self, ... }:
{
  flake.nixosModules.default = self.nixosModules.packages;
  flake.nixosModules.packages =
    { pkgs, ... }:
    {
      # Unfree grants for the home lists below.
      unfreePackages = [
        "claude-code"
        "obsidian"
      ];

      # nvim exists only in the primary user's profile, so a system-wide
      # EDITOR=nvim would dangle for root and service users. That user gets
      # nvim back per-user and in the graphical session.
      environment.variables.EDITOR = "vim";

      # With the courtesy layer off, everything above the NixOS core set is
      # in the list below. nano ships its own default-enabled module and is
      # switched off separately.
      environment.defaultPackages = [ ];
      programs.nano.enable = false;

      environment.systemPackages = [
        # neovim is absent: NvChad's wrapper provides nvim per-user and a
        # plain install collides with it.
        pkgs.vim

        # nushell is here rather than only in a host's login-shell setting,
        # so the binary exists wherever a user picks it.
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

        # syscall tracing, for failures inside tight systemd sandboxes.
        pkgs.strace

        # ARCHIVES
        pkgs.p7zip
        pkgs.unzip
        pkgs.zip

        # git is here as well as in the home concern, since rebuilding this
        # repo needs it in root's PATH.
        pkgs.git
      ];
    };

  # The graphical session's utilities and applications. hyprshot wraps its
  # own grim, slurp and notification dependencies.
  flake.homeModules.desktop = self.homeModules.packages-desktop;
  flake.homeModules.packages-desktop =
    { config, pkgs, ... }:
    {
      home.packages = [
        # The session's elected applications (default-apps.mod.nix) that
        # no module below installs; referencing the options keeps a host
        # override installing its choice.
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

        # Installed only; DMS owns selection and wiring, writing
        # ~/.config/hypr/dms/cursor.lua, setting XCURSOR_THEME and
        # running hyprctl setcursor. home.pointerCursor is avoided
        # because it generates competing GTK and hyprcursor config.
        pkgs.bibata-cursors

        pkgs.brave
        pkgs.kdePackages.dolphin
        # Dolphin's archive context menu and GUI. Nothing else installs
        # an icon theme, and breeze-dark tracks the dark KColorScheme.
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
