# Config-less packages. Tools that carry configuration have their own concern
# files; Nix-workflow tools (nh, nix-output-monitor) live in nix.mod.nix;
# fonts in fonts.mod.nix.
#
# The system list is universal: available to root and every user on both host
# classes. Home lists gate themselves on isDesktop / cockpit.enable — that
# gating, not module naming, is how hosts differ (every module is imported
# into every host).
{ inputs, ... }:
{
  flake.nixosModules.packages =
    { pkgs, ... }:
    {
      # Codex releases move faster than nixos-unstable; take only this
      # package from master (see flake.nix).
      nixpkgs.overlays = [
        (_final: _prev: {
          codex = inputs.nixpkgs-master.legacyPackages.${pkgs.stdenv.hostPlatform.system}.codex;
        })
      ];

      # vim, not nvim: nvim exists only in the primary user's profile, so a
      # system-wide EDITOR=nvim dangles for root and service users (e.g.
      # visudo). The primary user gets nvim back per-user (editors.mod.nix)
      # and in the graphical session (hyprland.mod.nix env).
      environment.variables.EDITOR = "vim";

      environment.systemPackages = [
        # editors: neovim absent — NvChad's wrapper provides `nvim` per-user
        # (see editors.mod.nix) and collides with a plain install.
        pkgs.vim

        # interactive CLI quality-of-life. nushell is here (not only a
        # host's login shell setting) so the binary exists system-wide
        # wherever a user picks it.
        pkgs.eza
        pkgs.fd
        pkgs.fzf
        pkgs.htop
        pkgs.nushell
        pkgs.ripgrep
        pkgs.tmux
        pkgs.tree

        # network
        pkgs.dig
        pkgs.traceroute
        pkgs.wget

        # archives
        pkgs.p7zip
        pkgs.unzip
        pkgs.zip

        # dev: git is here (not only in the home git concern) because
        # managing and rebuilding this flake repo requires it in root's PATH.
        pkgs.git
        pkgs.gnumake
      ];
    };

  # The graphical session's loose utilities and applications (the apps are
  # wired into the Hyprland quick-app bindings). hyprshot wraps its own
  # grim/slurp (and notification) dependencies.
  flake.homeModules.packages-desktop =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf osConfig.isDesktop {
        home.packages = [
          pkgs.brightnessctl
          pkgs.cliphist
          pkgs.hyprpicker
          pkgs.hyprshot
          pkgs.pavucontrol
          pkgs.playerctl
          pkgs.wl-clip-persist
          pkgs.wl-clipboard

          # Pointer cursor theme only INSTALLED here; selection and wiring
          # are DMS-owned (its cursor settings write
          # ~/.config/hypr/dms/cursor.lua — required by the Hyprland config,
          # see hyprland.mod.nix — set XCURSOR_THEME for launched apps, and
          # run hyprctl setcursor). home.pointerCursor is deliberately NOT
          # used: it would generate competing GTK/x11/hyprcursor config.
          pkgs.bibata-cursors

          pkgs.brave
          pkgs.kdePackages.dolphin
          # Dolphin's Extract/Compress context menu + the archive GUI. Icons:
          # nothing else installs an icon theme, and breeze-dark tracks the
          # dark KColorScheme (see kde.mod.nix for both wirings).
          pkgs.kdePackages.ark
          pkgs.kdePackages.breeze-icons
          pkgs.keepassxc
          pkgs.libreoffice
          pkgs.obsidian
          pkgs.signal-desktop
        ];
      };
    };

  # Authoring/build tools for anywhere the user actually works: workstations
  # and the model-agnostic cockpit host (see cockpit.mod.nix).
  flake.homeModules.packages-dev-extras =
    {
      lib,
      osConfig,
      pkgs,
      ...
    }:
    let
      inherit (lib.modules) mkIf;
    in
    {
      config = mkIf (osConfig.isDesktop || osConfig.cockpit.enable) {
        home.packages = [
          pkgs.cargo
          pkgs.claude-code
          pkgs.clippy
          pkgs.codex
          pkgs.gcc
          pkgs.opencode
          pkgs.hugo
          # The codex Claude Code plugin's hooks invoke `node` directly.
          pkgs.nodejs
          pkgs.rust-analyzer
          pkgs.rustc
          pkgs.rustfmt
        ];
      };
    };
}
