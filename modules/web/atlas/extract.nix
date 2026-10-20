# What the atlas learns from evaluating each host: which of the ship's
# files make it up, the services, routes and secrets each file declares,
# and which file configures or reads which. Reading the module system's
# own records (the import graph, each option's declarations and
# definitions) keeps the map exact without a parser for Nix.
{ lib, self }:
let
  inherit (lib.attrsets)
    attrNames
    attrValues
    filterAttrs
    mapAttrsToList
    ;
  inherit (lib.lists)
    concatMap
    elem
    filter
    head
    isList
    unique
    ;
  inherit (lib.strings)
    match
    readFile
    split
    unsafeDiscardStringContext
    ;
  inherit (lib) isAttrs;
  inherit (lib.options) isOption showOption;

  src = unsafeDiscardStringContext (toString self);
  # The repository path of a module file, or null outside the ship.
  # flake-parts files read "<path>, via option flake.nixosModules.<name>".
  rel =
    f:
    let
      m = match "${src}/([^,]*)(, via .*)?" (unsafeDiscardStringContext (toString f));
    in
    if m == null then null else head m;
  rels = fs: unique (filter (f: f != null) (map rel fs));

  nixFiles = filter (lib.strings.hasSuffix ".nix") (lib.filesystem.listFilesRecursive self);
  # The option namespaces the ship declares, found as `options.<name>`.
  namespaces = unique (
    concatMap (
      f: filter isList (split "options\\.([A-Za-z_][A-Za-z0-9_-]*)" (readFile f)) |> map head
    ) nixFiles
  );

  host =
    name: sys:
    let
      inherit (sys) config options;

      walk = m: [ m ] ++ concatMap walk m.imports;
      nodes = concatMap walk sys.graph;
      # Named flake modules ("lab", "desktop") and the files under each.
      bundle = k: match ".*#nixosModules\\.([A-Za-z0-9_-]+)" (toString k);
      bundles = unique (
        concatMap (
          n:
          let
            b = bundle n.key;
          in
          if b == null then
            [ ]
          else
            map (f: {
              name = head b;
              file = f;
            }) (rels (map (m: m.file) (walk n)))
        ) nodes
      );

      leaves = o: if isOption o then [ o ] else concatMap leaves (attrValues o);
      ours = filter (n: options ? ${n} && n != "flake") namespaces;
      opts = map (o: {
        name = showOption o.loc;
        declared = rels o.declarations;
        set = rels (map (d: d.file) o.definitionsWithLocations);
      }) (concatMap (n: leaves options.${n}) ours);

      # Names each file defines under an attrsOf option, with the file.
      defined =
        opt:
        concatMap (
          d:
          let
            f = rel d.file;
          in
          if f == null || !isAttrs d.value then [ ] else map (n: { inherit n f; }) (attrNames d.value)
        ) opt.definitionsWithLocations;
      byName =
        ds: lib.lists.groupBy (d: d.n) ds |> lib.attrsets.mapAttrs (_: ds: unique (map (d: d.f) ds));

      # A definition under a false mkIf names a unit the host lacks.
      services = filterAttrs (n: _: config.systemd.services ? ${n}) (
        byName (defined options.systemd.services)
      );
      units = attrNames services;
      wiring =
        u:
        let
          s = config.systemd.services.${u};
          pick = l: filter (x: elem (lib.strings.removeSuffix ".service" x) units && x != "${u}.service") l;
        in
        {
          files = services.${u};
          after = map (lib.strings.removeSuffix ".service") (
            unique (pick (s.after ++ s.requires ++ s.wants ++ s.bindsTo))
          );
          description = s.description or "";
          timer = config.systemd.timers ? ${u};
        };

      routeFiles = if options ? shipProxy then byName (defined options.shipProxy.routes) else { };
      # The atlas's own route is skipped: its root is this very data.
      routes = lib.attrsets.mapAttrs (n: r: {
        subdomain = r.subdomain;
        port = r.port;
        static = r.root != null;
        upstream = r.upstream;
        files = routeFiles.${n} or [ ];
      }) (filterAttrs (n: _: n != "atlas") (config.shipProxy.routes or { }));

      secrets = if options ? secrets then byName (defined options.secrets) else { };
    in
    {
      inherit
        name
        bundles
        routes
        secrets
        ;
      files = rels (map (n: n.file) nodes);
      system = config.nixpkgs.hostPlatform.system;
      user = config.primaryUser or null;
      options = opts;
      services = lib.attrsets.genAttrs units wiring;
      ports = rels [ ];
    };
in
{
  inherit namespaces;
  hosts = mapAttrsToList host self.nixosConfigurations;
}
