# Every alarm becomes a message in Sokka's chat. Four sensors feed it: a
# global OnFailure drop-in, a 6-hourly sweep for conditions OnFailure
# cannot see, smartd's -M exec hook, and upsmon's NOTIFYCMD spool. Each
# writes through ship-alert into the spool; on Water, Sokka sends what
# lands there and deletes it, and on other hosts a relay hands each alert
# to Water's receiver over the tailnet, deleting it once Water has it.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.alerts;
  flake.nixosModules.alerts =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.modules) mkIf mkMerge;
      inherit (lib.options) mkEnableOption mkOption;
      inherit (lib) types;

      cfg = config.alerts;
      hostname = config.networking.hostName;
      inherit (cfg) spool;
      port = 7749;
      # Longest alert kept; the rest is cut.
      max = 4000;

      # Sensors write files and nothing else; /var/lib/alerts holds the
      # throttle marks.
      sensorHardening = lib.ship.hardened.rootSensor // {
        IPAddressDeny = "any";
        ReadWritePaths = [
          spool
          "/var/lib/alerts"
        ];
      };

      # Files start with a dot and are renamed into place, so the reader
      # never sees half an alert. The group (setgid spool) may read them.
      enqueue = ''
        umask 027
        name=$(date +%s%N)-$$
        printf '%s\n' "$body" > ${spool}/.$name
        mv ${spool}/.$name ${spool}/$name
      '';

      # usage: ship-alert [--throttle-minutes N] < body
      # Throttled bodies are dropped while an identical one was queued
      # within N minutes.
      shipAlert = pkgs.writeShellApplication {
        name = "ship-alert";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.findutils
        ];
        text = ''
          minutes=0
          if [ "''${1:-}" = --throttle-minutes ]; then minutes=$2; fi
          body=$(head -c ${toString max})
          [ -n "$body" ] || exit 0
          if [ "$minutes" -gt 0 ]; then
            mark=/var/lib/alerts/throttle-$(printf %s "$body" | sha256sum | cut -c1-16)
            if [ -n "$(find "$mark" -mmin -"$minutes" 2>/dev/null)" ]; then exit 0; fi
            touch "$mark"
          fi
          ${enqueue}
        '';
      };

      smartdHook = pkgs.writeShellApplication {
        name = "ship-alert-smart";
        runtimeInputs = singleton shipAlert;
        text = ''
          printf '💽 %s: SMART %s on %s\n%s' \
            ${hostname} "''${SMARTD_FAILTYPE:-event}" "''${SMARTD_DEVICE:-?}" \
            "''${SMARTD_MESSAGE:-no detail}" \
            | ship-alert --throttle-minutes 360
        '';
      };

      # NOTIFYCMD runs unprivileged and only spools; the path unit relays.
      upsSpool = "/var/lib/nut-alerts";
      upsNotify = pkgs.writeShellApplication {
        name = "ship-alert-ups-spool";
        runtimeInputs = singleton pkgs.coreutils;
        text = ''
          printf '%s %s\n' "''${NOTIFYTYPE:-EVENT}" "$*" \
            > ${upsSpool}/.$$.tmp && mv ${upsSpool}/.$$.tmp "${upsSpool}/$(date +%s%N)"
        '';
      };

      # Shipped via systemd.packages because environment.etc cannot nest
      # under the generated /etc/systemd/system. The zz- drop-in sorts after
      # 99- and clears OnFailure, so a broken alert path cannot recurse.
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
        spool = mkOption {
          type = types.str;
          default = "/var/spool/alerts";
          readOnly = true;
          description = "Directory the sensors write alerts into, one file each.";
        };

        reader = mkOption {
          type = types.str;
          default = "root";
          description = ''
            User whose process sends the alerts in the spool and deletes
            them; its group owns the spool.
          '';
        };

        relay.to = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Tailnet address of the host that posts this host's alerts.";
        };

        relay.from = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Tailnet addresses whose alerts this host accepts and posts.";
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
          description = "smartd disk-health alerts, with scheduled self-tests.";
        };

        ups.enable = mkEnableOption "NUT monitoring of the USB-attached UPS (probe the hardware first)";

      };

      config = mkMerge [
        {
          systemd.packages = singleton onFailureDropins;
          environment.systemPackages = singleton shipAlert;

          systemd.tmpfiles.rules = [
            "d ${spool} 2770 root ${config.users.users.${cfg.reader}.group} -"
            "d /var/lib/alerts 0700 root root -"
          ];

          systemd.services."alert-unit-failure@" = {
            description = "Alert that %i failed";
            # Journal reads and D-Bus need uid 0.
            serviceConfig = sensorHardening // {
              Type = "oneshot";
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
                | ship-alert
            '';
          };

          systemd.services.alert-sweep = {
            description = "Sweep for failed units, full disks, and heat";
            serviceConfig = sensorHardening // {
              Type = "oneshot";
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

              # A new kernel, initrd or kernel parameter only takes effect
              # on reboot, which is left to a human.
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
            wantedBy = singleton "timers.target";
            timerConfig = {
              OnBootSec = "10min";
              OnUnitActiveSec = "6h";
            };
          };
        }

        (mkIf cfg.smart.enable {
          # -n standby avoids spinning up sleeping disks.
          services.smartd = {
            enable = true;
            autodetect = true;
            notifications.mail.enable = false;
            notifications.wall.enable = false;
            defaults.autodetected = "-a -o on -S on -n standby,q -s (S/../../6/02|L/../01/./04) -m root -M exec ${getExe smartdHook}";
          };
        })

        (mkIf cfg.ups.enable {
          # The EcoFlow speaks USB HID PDC.
          power.ups = {
            enable = true;
            mode = "standalone";
            ups.house = {
              driver = "usbhid-ups";
              port = "auto";
              directives = singleton "vendorid = 3746";
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
            upsmon.settings.NOTIFYFLAG =
              map
                (event: [
                  event
                  "SYSLOG+EXEC"
                ])
                [
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

          system.activationScripts.nut-upsmon-password = ''
            mkdir -p /var/lib/nut
            if [ ! -s /var/lib/nut/upsmon.password ]; then
              # Written to a temp name and renamed, so an interrupted write
              # cannot leave a partial password that then sticks forever.
              (
                umask 077
                tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 \
                  > /var/lib/nut/upsmon.password.new
              )
              mv -T /var/lib/nut/upsmon.password.new /var/lib/nut/upsmon.password
            fi
          '';

          # The group is nutmon, not nut; there is no nut group, and
          # tmpfiles silently skips a rule naming one.
          systemd.tmpfiles.rules = singleton "d ${upsSpool} 0770 root ${config.power.ups.upsmon.group} -";

          systemd.paths.alert-ups = {
            description = "Watch for spooled UPS events";
            wantedBy = singleton "multi-user.target";
            pathConfig = {
              PathExistsGlob = "${upsSpool}/[0-9]*";
              Unit = "alert-ups.service";
            };
          };

          systemd.services.alert-ups = {
            description = "Turn spooled UPS events into alerts";
            serviceConfig = sensorHardening // {
              Type = "oneshot";
              # Written by nutmon, which may not write the alert spool.
              ReadWritePaths = sensorHardening.ReadWritePaths ++ singleton upsSpool;
            };
            path = [
              pkgs.coreutils
              shipAlert
            ];
            script = ''
              for event in ${upsSpool}/[0-9]*; do
                [ -f "$event" ] || continue
                printf '🔋 %s: UPS %s' ${hostname} "$(cat "$event")" | ship-alert
                rm -f "$event"
              done
            '';
          };
        })

        (mkIf (cfg.relay.to != null) {
          systemd.paths.alert-relay = {
            description = "Watch for alerts to hand to ${cfg.relay.to}";
            wantedBy = singleton "multi-user.target";
            pathConfig = {
              PathExistsGlob = "${spool}/[0-9]*";
              Unit = "alert-relay.service";
            };
          };

          # An alert is deleted only once the receiver answers ok. On
          # failure this backs off and exits 0, leaving the path condition
          # true so the unit retries instead of hot-looping.
          systemd.services.alert-relay = {
            description = "Hand alerts to ${cfg.relay.to}";
            serviceConfig = lib.ship.hardened.rootSensor // {
              Type = "oneshot";
              ReadWritePaths = singleton spool;
              IPAddressAllow = cfg.relay.to;
              IPAddressDeny = "any";
            };
            path = [
              pkgs.coreutils
              pkgs.socat
            ];
            script = ''
              for alert in ${spool}/[0-9]*; do
                [ -f "$alert" ] || continue
                reply=$(socat -T 30 - "TCP:${cfg.relay.to}:${toString port},connect-timeout=10" < "$alert" || true)
                if [ "$reply" = ok ]; then
                  rm -f "$alert"
                else
                  sleep 60
                  exit 0
                fi
              done
            '';
          };
        })

        (mkIf (cfg.relay.from != [ ]) {
          # The tailnet interface is trusted by the firewall; the socket
          # itself admits only the listed senders.
          systemd.sockets.alert-receive = {
            description = "Alerts from other hosts";
            wantedBy = singleton "sockets.target";
            socketConfig = {
              ListenStream = port;
              Accept = true;
              MaxConnections = 8;
              IPAddressAllow = cfg.relay.from;
              IPAddressDeny = "any";
            };
          };

          systemd.services."alert-receive@" = {
            description = "Spool one alert from another host";
            serviceConfig = lib.ship.hardened.tenant // {
              User = cfg.reader;
              Group = config.users.users.${cfg.reader}.group;
              StandardInput = "socket";
              StandardOutput = "socket";
              StandardError = "journal";
              RuntimeMaxSec = 60;
              PrivateNetwork = true;
              ReadWritePaths = singleton spool;
              InaccessiblePaths = singleton config.users.users.${cfg.reader}.home;
            };
            path = singleton pkgs.coreutils;
            script = ''
              body=$(head -c ${toString max})
              [ -n "$body" ] || exit 0
              ${enqueue}
              echo ok
            '';
          };
        })
      ];
    };
}
