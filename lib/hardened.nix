# Shared systemd hardening presets — plain data, the network-fences.nix
# shape. Unit specifics (user, state directory, slice, egress fence) stay
# per-unit; these are the directives every consumer wants identically.
#
# `tenant`: unprivileged services that parse untrusted input or hold a
# credential (remy, curtisbot, fleet-log-stream). None of them binds a
# port, so SocketBindDeny is free defense.
#
# `rootSensor`: root oneshots that read the journal/sysfs or query systemd
# over D-Bus (the alert units). Differs from tenant in exactly two ways:
# no PrivateUsers (the system bus authenticates by peer uid, which must
# stay 0) and AF_UNIX allowed (D-Bus).
let
  tenant = {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProcSubset = "pid";
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SocketBindDeny = "any";
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" ];
    SystemCallErrorNumber = "EPERM";
    UMask = "0077";
  };
in
{
  inherit tenant;

  rootSensor = builtins.removeAttrs tenant [ "PrivateUsers" ] // {
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
  };
}
