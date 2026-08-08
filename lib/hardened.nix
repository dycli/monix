# Shared systemd hardening presets. Unit specifics (user, state directory,
# egress fence) stay per-unit.
let
  # tenant: unprivileged services that parse untrusted input or hold a
  # credential. None binds a port.
  tenant = {
    CapabilityBoundingSet = "";
    # These processes hold credentials in memory.
    LimitCORE = 0;
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateIPC = true;
    PrivateTmp = true;
    PrivateUsers = true;
    RemoveIPC = true;
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

  # rootSensor: root oneshots reading the journal or sysfs, or querying
  # systemd over D-Bus. The system bus authenticates by peer uid, which must
  # stay 0, so PrivateUsers is dropped; AF_UNIX carries D-Bus.
  rootSensor = builtins.removeAttrs tenant [ "PrivateUsers" ] // {
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
  };

  # vendor: third-party services whose nixpkgs modules ship little isolation.
  # Drops SocketBindDeny (they listen), PrivateUsers (a uid map breaks files
  # shared through a common group) and UMask=0077 (that output stays
  # group-readable). Under ProtectSystem=strict each consumer must declare
  # ReadWritePaths for anything it writes outside its StateDirectory, or the
  # unit starts and then cannot save.
  vendor =
    builtins.removeAttrs tenant [
      "SocketBindDeny"
      "PrivateUsers"
      "UMask"
    ]
    // {
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      SystemCallFilter = [
        "@system-service"
        "@chown"
      ];
    };
}
