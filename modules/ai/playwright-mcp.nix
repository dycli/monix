# Playwright MCP with Brave as its browser. The nixpkgs wrapper retains
# every bundled Playwright browser; only the JS library is kept, and the
# wrapper that references the redundant browser closure is removed.
pkgs:
let
  playwrightLibrary = pkgs.playwright-test.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      rm -rf "$out/bin"
    '';
  });
in
pkgs.playwright-mcp.overrideAttrs {
  postInstall = ''
    pkg_dir="$out/lib/node_modules/@playwright/mcp"
    rm -rf "$pkg_dir/node_modules/playwright"
    rm -rf "$pkg_dir/node_modules/playwright-core"
    ln -s ${playwrightLibrary}/lib/node_modules/playwright "$pkg_dir/node_modules/playwright"
    ln -s ${playwrightLibrary}/lib/node_modules/playwright-core "$pkg_dir/node_modules/playwright-core"
  '';
}
