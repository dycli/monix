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
    # No core dumps: these processes hold credentials in memory.
    LimitCORE = 0;
    LockPersonality = true;
    NoNewPrivileges = true;
    # PrivateDevices implies DevicePolicy=closed, so that isn't set here.
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

  rootSensor = builtins.removeAttrs tenant [ "PrivateUsers" ] // {
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
  };

  # `vendor`: a third-party service whose nixpkgs module ships little or
  # no isolation of its own. A general-purpose module has to run on
  # everyone's machine, so being permissive there is the right call —
  # tightening is a downstream job for whoever knows the deployment, and
  # that is us. NOT a claim that those modules are wrong.
  #
  # Differs from `tenant` in four ways, each because these daemons do
  # things our own programs do not:
  #   - no SocketBindDeny: they listen on a port.
  #   - no PrivateUsers: they share files with other services through a
  #     common group, and a uid map makes that ownership incoherent.
  #   - no UMask=0077: same reason — group-readable output is the point.
  #   - AF_UNIX allowed, and @chown kept: glibc NSS may use a local
  #     socket, and these services chown/chmod what they write (sonarr's
  #     own module keeps @chown for exactly this).
  #
  # ProtectSystem=strict means the CONSUMER must declare ReadWritePaths
  # for anything it writes outside its StateDirectory — the media tree,
  # typically. Getting that wrong shows up as a service that starts and
  # then cannot save a file, so verify functionally, not just by starting.
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
