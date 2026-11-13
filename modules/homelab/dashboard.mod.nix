# The house's dashboard at https://home.<domain>, served by ./dashboard: the
# services and the host's health, the calendar, forecast and air (from hob),
# plus Agents (the assistants and subscription use) and Monitoring tabs.
# Reached through the tailnet's TLS proxy only.
{ self, ... }:
{
  flake.nixosModules.lab = self.nixosModules.dashboard;
  flake.nixosModules.dashboard =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib.attrsets) optionalAttrs;
      inherit (lib.strings) concatStringsSep toJSON;
      inherit (lib.lists) singleton;
      inherit (lib.meta) getExe;
      inherit (lib.options) mkOption;
      inherit (lib) types;
      inherit (lib.ship) fences;

      cfg = config.dashboard;
      port = 8971;
      dashboard = lib.ship.rustTool pkgs { src = ./dashboard; };
      # The subscription-use socket (../ai/usage.mod.nix), where the host runs it.
      usage = config.systemd.sockets ? usage;
    in
    {
      options.dashboard = {
        services = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                name = mkOption { type = types.str; };
                about = mkOption {
                  type = types.str;
                  default = "";
                };
                icon = mkOption {
                  type = types.str;
                  default = "";
                  description = "Name in the dashboard-icons set, e.g. `sonarr`.";
                };
                route = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "shipProxy route the service is reached by.";
                };
                url = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Address to open, for a service without a route.";
                };
                check = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Loopback address to check; defaults to the route's port.";
                };
                agent = mkOption {
                  type = types.bool;
                  default = false;
                  description = "An assistant: the Agents tab lists it too.";
                };
              };
            }
          );
          default = [ ];
          description = "Services the dashboard lists and checks, in order.";
        };
        disks = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                label = mkOption { type = types.str; };
                path = mkOption { type = types.str; };
              };
            }
          );
          default = [ ];
          description = "Filesystems the dashboard shows, in order.";
        };
      };

      config = {
        shipProxy.routes.home.port = port;

        systemd.services.dashboard = {
          description = "The house's dashboard";
          wantedBy = singleton "multi-user.target";
          environment = {
            DASHBOARD_LISTEN = "127.0.0.1:${toString port}";
            DASHBOARD_HOB = "http://127.0.0.1:${toString config.services.hob.port}";
          }
          // optionalAttrs (cfg.services != [ ]) {
            DASHBOARD_SERVICES =
              cfg.services
              |> map (
                s:
                let
                  route = config.shipProxy.routes.${s.route};
                in
                {
                  inherit (s)
                    name
                    about
                    icon
                    agent
                    ;
                  url = if s.route != null then "https://${route.subdomain}.${config.shipProxy.domain}" else s.url;
                  check = if s.check != null then s.check else "http://127.0.0.1:${toString route.port}/";
                }
              )
              |> toJSON;
          }
          // optionalAttrs (cfg.disks != [ ]) {
            DASHBOARD_DISKS = cfg.disks |> map (d: "${d.label}=${d.path}") |> concatStringsSep ",";
          }
          // optionalAttrs usage {
            DASHBOARD_USAGE = "/run/usage.sock";
          };
          serviceConfig =
            lib.ship.hardened.tenant
            // {
              DynamicUser = true;
              # The dashboard reads the host's load, memory and uptime from /proc.
              ProcSubset = "all";
              ExecStart = getExe dashboard;
              Restart = "on-failure";
              SocketBindDeny = "any";
              SocketBindAllow = singleton "tcp:${toString port}";
              # Loopback (hob, the services it checks) only.
              IPAddressAllow = fences.loopback;
              IPAddressDeny = "any";
            }
            // optionalAttrs usage {
              # The Agents tab reads subscription use from the usage socket,
              # which its group may open; a private user namespace would hide
              # the group.
              SupplementaryGroups = singleton "usage";
              PrivateUsers = false;
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
            };
        };
      };
    };
}
