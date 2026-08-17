//@ pragma AppId org.kestrel.shell
//@ pragma Env QT_WAYLAND_DISABLE_WINDOWDECORATION=1

import Quickshell
import Quickshell.Io

ShellRoot {
    Bar {}

    IpcHandler {
        target: "power"

        function toggleIdleInhibit(): void {
            PowerService.idleInhibited = !PowerService.idleInhibited;
        }

        function idleInhibited(): bool {
            return PowerService.idleInhibited;
        }
    }
}
