# Ship alerting — every alarm on the host reaches the Matrix alert room
# through one Rust mouth (alerts/ship-alert), and every sensor is a borrowed
# specialist with a thin hook:
#
#   1. systemd (software): a GLOBAL drop-in (service.d/, shipped via
#      systemd.packages — environment.etc can't nest under the generated
#      /etc/systemd/system) attaches OnFailure=alert-unit-failure@%n to every
#      system service, so any failure posts the unit name and a journal tail
#      within seconds.
#   2. The 6-hourly sweep: still-failed units, filesystems over the disk
#      threshold, hwmon temperatures over the heat threshold, and a pending
#      kernel (what OnFailure can't see: units already failed at boot,
#      creeping usage, dying fans).
#   3. smartd (disks): SMART health/attribute/self-test events fire a -M exec
#      hook; scheduled short/long self-tests keep the attributes honest.
#   4. upsmon (power, optional): NOTIFYCMD spools events as the unprivileged
#      nut user; a path unit relays them as root. LOWBATT keeps upsmon's
#      clean-shutdown behavior.
#
# ship-alert owns delivery: password login → send → logout on the loopback
# tuwunel (no device accumulation), one-time room join stamped in
# /var/lib/alerts, optional local-LLM enrichment, repeat throttling. If the
# homeserver is down alerts can't send; accepted — meta-monitoring needs an
# off-host watcher, which this deliberately is not.
#
# The env secret carries MATRIX_USER, MATRIX_PASSWORD, and ALERT_ROOM_ID —
# room id included so nothing about the room lives in the repo and the
# host wiring can gate on the one secret existing.
{
  flake.nixosModules.alerts =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf mkMerge;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib.strings) hasSuffix optionalString;
      inherit (lib) types;

      cfg = config.alerts;
      hostname = config.networking.hostName;

      shipAlert = pkgs.rustPlatform.buildRustPackage {
        pname = "ship-alert";
        version = "0.1.0";
        src = lib.sources.cleanSourceWith {
          src = ./alerts/ship-alert;
          filter = path: type: type != "directory" || !hasSuffix "/target" (toString path);
        };
        cargoLock.lockFile = ./alerts/ship-alert/Cargo.lock;
        env = {
          SHIP_ALERT_HOMESERVER = cfg.homeserverUrl;
          SHIP_ALERT_STATE_DIR = "/var/lib/alerts";
          SHIP_ALERT_SUMMARY_URL = optionalString cfg.summary.enable cfg.summary.url;
          SHIP_ALERT_SUMMARY_MODEL = cfg.summary.model;
          SHIP_ALERT_CURL = "${pkgs.curl}/bin/curl";
        };
        meta.mainProgram = "ship-alert";
      };

      # Hooks run by daemons that don't carry the Matrix credentials in their
      # own environment (smartd, the UPS relay) source the agenix env file
      # themselves; both run as root.
      withCredentials = ''
        set -a
        # shellcheck disable=SC1091
        . ${cfg.credentialsEnvFile}
        set +a
      '';

      smartdHook = pkgs.writeShellApplication {
        name = "ship-alert-smart";
        runtimeInputs = [ shipAlert ];
        text = ''
          ${withCredentials}
          printf '💽 %s: SMART %s on %s\n%s' \
            ${hostname} "''${SMARTD_FAILTYPE:-event}" "''${SMARTD_DEVICE:-?}" \
            "''${SMARTD_MESSAGE:-no detail}" \
            | ship-alert --throttle-minutes 360
        '';
      };

      # upsmon runs NOTIFYCMD unprivileged, so it only spools; the path unit
      # below relays as root with the credentials.
      upsSpool = "/var/lib/nut-alerts";
      upsNotify = pkgs.writeShellApplication {
        name = "ship-alert-ups-spool";
        text = ''
          printf '%s %s\n' "''${NOTIFYTYPE:-EVENT}" "$*" \
            > ${upsSpool}/.$$.tmp && mv ${upsSpool}/.$$.tmp "${upsSpool}/$(date +%s%N)"
        '';
      };

      # The zz- drop-in sorts after 99- within the alert unit's own drop-in
      # set and clears OnFailure there, so a broken alert path can't
      # recurse; the script guard below is the second line of defense.
      onFailureDropins = pkgs.runCommand "alert-onfailure-dropins" { } ''
        mkdir -p $out/etc/systemd/system/service.d
        mkdir -p "$out/etc/systemd/system/alert-unit-failure@.service.d"
        cat > $out/etc/systemd/system/service.d/99-alert-on-failure.conf <<'EOF'
        [Unit]
        OnFailure=alert-unit-failure@%n.service
        EOF
        cat > "$out/etc/systemd/system/alert-unit-failure@.service.d/zz-no-self-alert.conf" <<'EOF'
        [Unit]
        OnFailure=
        EOF
      '';
    in
    {
      options.alerts = {
        enable = mkEnableOption "Matrix alerts for unit failures, disks, heat, and power";

        credentialsEnvFile = mkOption {
          type = types.path;
          description = ''
            agenix env file with MATRIX_USER=@bot:server,
            MATRIX_PASSWORD=..., and ALERT_ROOM_ID=!...:server — the alert
            bot's account (its only credential) and the room it posts to.
          '';
        };

        homeserverUrl = mkOption {
          type = types.str;
          default = "http://127.0.0.1:6167";
          description = "Homeserver base URL (default: the loopback tuwunel).";
        };

        diskPercentThreshold = mkOption {
          type = types.ints.between 1 99;
          default = 85;
          description = "Sweep alerts when a real filesystem exceeds this use%.";
        };

        tempCelsiusThreshold = mkOption {
          type = types.ints.between 40 120;
          default = 90;
          description = "Sweep alerts when any hwmon temperature exceeds this many °C.";
        };

        smart.enable = mkOption {
          type = types.bool;
          default = true;
          description = "smartd disk-health events into the alert room, with scheduled self-tests.";
        };

        ups.enable = mkEnableOption "NUT monitoring of the USB-attached UPS (probe the hardware first)";

        summary.enable = mkEnableOption "a local-LLM plain-language line atop failure alerts";

        summary.url = mkOption {
          type = types.str;
          default = "http://127.0.0.1:8091";
          description = "OpenAI-compatible endpoint (default: the local llama-swap).";
        };

        summary.model = mkOption {
          type = types.str;
          default = "qwen3.6-35b-a3b";
          description = "Model to summarize with.";
        };
      };

      config = mkIf cfg.enable (mkMerge [
        {
          systemd.packages = [ onFailureDropins ];
          environment.systemPackages = [ shipAlert ];

          systemd.services."alert-unit-failure@" = {
            description = "Post %i failure to the Matrix alert room";
            serviceConfig = {
              Type = "oneshot";
              EnvironmentFile = cfg.credentialsEnvFile;
              StateDirectory = "alerts";
            };
            scriptArgs = "%i";
            path = [
              pkgs.systemd
              shipAlert
            ];
            script = ''
              unit="$1"
              case "$unit" in alert-*) exit 0 ;; esac
              tail=$(journalctl -u "$unit" -n 12 --no-pager -o cat || true)
              printf '🔴 %s: %s failed\n%s' ${hostname} "$unit" "$tail" \
                | ship-alert ${optionalString cfg.summary.enable "--summarize"}
            '';
          };

          systemd.services.alert-sweep = {
            description = "Sweep for failed units, full disks, and heat";
            serviceConfig = {
              Type = "oneshot";
              EnvironmentFile = cfg.credentialsEnvFile;
              StateDirectory = "alerts";
            };
            path = [
              pkgs.systemd
              pkgs.gawk
              pkgs.coreutils
              shipAlert
            ];
            script = ''
              problems=""

              failed=$(systemctl --failed --no-legend --plain | awk '{print $1}')
              if [ -n "$failed" ]; then
                problems=$(printf '🔴 failed units:\n%s' "$failed")
              fi

              full=$(df --local -x tmpfs -x devtmpfs -x efivarfs \
                --output=pcent,target | tail -n +2 \
                | awk -v t=${toString cfg.diskPercentThreshold} \
                    '{ gsub(/%/,"",$1); if ($1+0 >= t) print $1 "% " $2 }')
              if [ -n "$full" ]; then
                problems=$(printf '%s\n💾 disk over ${toString cfg.diskPercentThreshold}%%:\n%s' "$problems" "$full")
              fi

              hot=""
              for sensor in /sys/class/hwmon/hwmon*/temp*_input; do
                [ -r "$sensor" ] || continue
                milli=$(cat "$sensor" 2>/dev/null) || continue
                degrees=$((milli / 1000))
                if [ "$degrees" -ge ${toString cfg.tempCelsiusThreshold} ]; then
                  chip=$(cat "$(dirname "$sensor")/name" 2>/dev/null || echo hwmon)
                  hot=$(printf '%s\n%s°C %s %s' "$hot" "$degrees" "$chip" "$(basename "$sensor" _input)")
                fi
              done
              if [ -n "$hot" ]; then
                problems=$(printf '%s\n🌡️ over ${toString cfg.tempCelsiusThreshold}°C:%s' "$problems" "$hot")
              fi

              # A switch that brought a new kernel (or initrd/kernel params)
              # only takes effect on reboot; scheduled reboots were considered
              # and rejected (2026-07-13) in favor of this deliberate signal.
              booted=$(readlink -f /run/booted-system/kernel)
              current=$(readlink -f /run/current-system/kernel)
              if [ "$booted" != "$current" ]; then
                problems=$(printf '%s\n🔁 running an older kernel than the config — reboot when convenient' "$problems")
              fi

              if [ -n "$problems" ]; then
                printf '%s sweep:\n%s' ${hostname} "$problems" | ship-alert
              fi
            '';
          };

          systemd.timers.alert-sweep = {
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = "10min";
              OnUnitActiveSec = "6h";
            };
          };
        }

        (mkIf cfg.smart.enable {
          # smartd is the disk monitor; we only give it a mouth. -a monitors
          # everything, self-tests run short/Saturday-early and long/first-
          # Sunday-monthly, -n standby avoids spinning up sleeping disks.
          services.smartd = {
            enable = true;
            autodetect = true;
            notifications.mail.enable = false;
            notifications.wall.enable = false;
            defaults.autodetected = "-a -o on -S on -n standby,q -s (S/../../6/02|L/../01/./04) -m root -M exec ${getExe smartdHook}";
          };
        })

        (mkIf cfg.ups.enable {
          # The EcoFlow speaks USB HID PDC (probed before enabling). upsmon's
          # default LOWBATT behavior — clean shutdown — is exactly what the
          # un-backed-up family state wants.
          power.ups = {
            enable = true;
            mode = "standalone";
            ups.house = {
              driver = "usbhid-ups";
              port = "auto";
              directives = [ "vendorid = 3746" ];
            };
            users.upsmon = {
              passwordFile = "/var/lib/nut/upsmon.password";
              upsmon = "primary";
            };
            upsmon.monitor.house = {
              user = "upsmon";
              passwordFile = "/var/lib/nut/upsmon.password";
            };
            upsmon.settings.NOTIFYCMD = getExe upsNotify;
            upsmon.settings.NOTIFYFLAG = map (event: [ event "SYSLOG+EXEC" ]) [
              "ONLINE"
              "ONBATT"
              "LOWBATT"
              "FSD"
              "COMMOK"
              "COMMBAD"
              "SHUTDOWN"
              "REPLBATT"
              "NOCOMM"
            ];
          };

          # A local-only secret guarding a loopback socket: generated once,
          # root-owned; never leaves the machine.
          system.activationScripts.nut-upsmon-password = ''
            mkdir -p /var/lib/nut
            if [ ! -s /var/lib/nut/upsmon.password ]; then
              tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 > /var/lib/nut/upsmon.password
              chmod 0600 /var/lib/nut/upsmon.password
            fi
          '';

          systemd.tmpfiles.rules = [ "d ${upsSpool} 0770 root nut -" ];

          systemd.paths.alert-ups = {
            description = "Watch for spooled UPS events";
            wantedBy = [ "multi-user.target" ];
            pathConfig = {
              PathExistsGlob = "${upsSpool}/[0-9]*";
              Unit = "alert-ups.service";
            };
          };

          systemd.services.alert-ups = {
            description = "Relay spooled UPS events to the Matrix alert room";
            serviceConfig = {
              Type = "oneshot";
              EnvironmentFile = cfg.credentialsEnvFile;
              StateDirectory = "alerts";
            };
            path = [
              pkgs.coreutils
              shipAlert
            ];
            script = ''
              for event in ${upsSpool}/[0-9]*; do
                [ -f "$event" ] || continue
                printf '🔋 %s: UPS %s' ${hostname} "$(cat "$event")" | ship-alert || true
                rm -f "$event"
              done
            '';
          };
        })
      ]);
    };
}
