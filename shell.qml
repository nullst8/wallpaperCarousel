import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Standalone Quickshell entry point.
//
// This shell owns the whole wallpaper pipeline itself: it watches a JSON config
// file for settings, tracks the current wallpaper per output by asking awww
// (an swww fork) and by remembering its own picks, applies picks through
// `awww img`, and finds the focused output via Hyprland's IPC.
//
//   qs -p <this directory>  — start it (login-time daemon)
//   qs -p <dir> ipc call wallpaperCarousel toggle|open|close|cycleNext|…
//                           — the command surface (declared in Carousel.qml)
//
// Config lives in ${XDG_CONFIG_HOME:-~/.config}/wallpaperCarousel/settings.json.
// The file is optional: every key has a default here, and watching the file
// means edits apply live — no restart needed.

ShellRoot {
    id: root

    // ── Paths ─────────────────────────────────────────────────────────────────

    readonly property string home: Quickshell.env("HOME") || "/tmp"
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config")
    readonly property string configPath: root.configHome + "/wallpaperCarousel/settings.json"

    // ── Settings ──────────────────────────────────────────────────────────────
    //
    // Defaults mirror the plugin builds' manifest. `expandSelected` and
    // `enableHoldExpand` accept booleans here; Carousel also tolerates the
    // string forms used by the old plugin manifests.

    readonly property var configDefaults: ({
        wallpaperDirectory: "",
        carouselMode: "wrap",
        applyToAllMonitors: true,
        overlayOpacity: 80,
        borderWidth: 3,
        cornerRadius: 0,
        itemWidth: 300,
        itemHeight: 420,
        selectedScale: 108,
        expandSelected: false,
        expandMultiplier: 120,
        enableHoldExpand: false,
        holdExpandRatio: 35,
        holdDelay: 1500,
        cacheSize: 30,
        // awww transition applied on pick. transitionType "grow" grows a circle
        // from transitionPos; "" on duration/fps/pos leaves the daemon default.
        transitionType: "grow",
        transitionPos: "center",
        transitionDuration: "",
        transitionFps: "",
        // Optional per-output wallpaper directories, e.g. { "DP-1": "~/walls" }.
        monitorDirectories: {}
    })

    property var userConfig: ({})

    // Merged, with `~` expansion done here: Carousel feeds wallpaperDirectory
    // straight into a FolderListModel as `file://` + path, where a literal `~`
    // silently resolves to nothing.
    readonly property var cfg: {
        const merged = Object.assign({}, root.configDefaults, root.userConfig);
        merged.wallpaperDirectory = root.expandPath(String(merged.wallpaperDirectory ?? "").trim());
        return merged;
    }

    function expandPath(path) {
        const p = String(path ?? "");
        if (p === "~")
            return root.home;
        if (p.startsWith("~/"))
            return root.home + p.substring(1);
        return p;
    }

    // watchChanges cannot watch a file that does not exist yet, so a config
    // created after startup is found by polling until the first successful
    // load; from then on the file watcher takes over.
    Timer {
        id: configWatchTimer
        interval: 2000
        repeat: true
        onTriggered: configFile.reload()
    }

    FileView {
        id: configFile
        path: root.configPath
        watchChanges: true

        onFileChanged: reload()
        onLoaded: {
            configWatchTimer.stop();
            root.readConfig();
        }
        onLoadFailed: configWatchTimer.start()
    }

    // The file may be written non-atomically; retry briefly on a bad read.
    Timer {
        id: configRetryTimer
        interval: 120
        onTriggered: configFile.reload()
    }

    function readConfig() {
        try {
            const parsed = JSON.parse(configFile.text());
            root.userConfig = (parsed && typeof parsed === "object" && !Array.isArray(parsed)) ? parsed : {};
            console.info("wallpaperCarousel: config loaded — directory: '" + root.cfg.wallpaperDirectory
                + "', mode: " + root.cfg.carouselMode);
        } catch (e) {
            configRetryTimer.restart();
        }
    }

    // ── Current wallpaper state ───────────────────────────────────────────────
    //
    // { [outputName]: path }, with "" as the shell-wide default — the same shape
    // the Noctalia v5 host pushed in. Seeded from `awww query`, refreshed each
    // time the overlay opens (so wallpapers changed by other tools are picked
    // up), and updated immediately on every pick (the daemon's own answer can
    // lag behind the just-issued `awww img`).

    property var currentWallpaperByScreen: ({})

    function monitorDirectory(screenName) {
        if (!screenName)
            return "";
        const dirs = root.cfg.monitorDirectories ?? {};
        const dir = dirs[screenName];
        return dir ? root.expandPath(String(dir).trim()) : "";
    }

    // Browsing directory when the user has not overridden wallpaperDirectory:
    // the per-output directory for the screen being browsed, else the directory
    // of the current wallpaper (matching the DMS build's "follow the wallpaper"
    // default), else ~/Pictures.
    function defaultWallpaperFolderFor(screenName) {
        const perMonitor = root.monitorDirectory(screenName);
        if (perMonitor)
            return perMonitor;

        const current = root.currentWallpaperByScreen[screenName]
            ?? root.currentWallpaperByScreen[""] ?? "";
        if (current) {
            const slash = current.lastIndexOf('/');
            if (slash > 0)
                return current.substring(0, slash);
        }

        return root.home + "/Pictures";
    }

    Process {
        id: queryProcess
        command: ["awww", "query"]

        stdout: StdioCollector {
            onStreamFinished: root.applyQueryResult(this.text)
        }

        // Daemon down? Start it once and try again; a login-time race with the
        // compositor's own autostart is the usual cause.
        onExited: (code, status) => {
            if (code !== 0 && !root.daemonRestartAttempted) {
                root.daemonRestartAttempted = true;
                console.warn("wallpaperCarousel: awww query failed, starting awww-daemon");
                Quickshell.execDetached(["awww-daemon"]);
                daemonStartTimer.start();
            }
        }
    }

    property bool daemonRestartAttempted: false

    Timer {
        id: daemonStartTimer
        interval: 800
        onTriggered: root.refreshWallpaperState()
    }

    function refreshWallpaperState() {
        queryProcess.running = true;
    }

    // `awww query` lines look like:
    //   eDP-1: 1920x1200, scale: 1, currently displaying: image: /path/to/img.jpg
    function applyQueryResult(text) {
        const next = Object.assign({}, root.currentWallpaperByScreen);
        let changed = false;
        for (const line of String(text ?? "").split("\n")) {
            const m = line.match(/^([^:]+):.*currently displaying: image: (.+)$/);
            if (m && next[m[1].trim()] !== m[2].trim()) {
                next[m[1].trim()] = m[2].trim();
                changed = true;
            }
        }
        if (changed)
            root.currentWallpaperByScreen = next;

        // The query is asynchronous, so an open that raced it may have focused
        // the wrong tile. Re-run the focus logic once the answer lands — the
        // first snap runs at zero duration, so this is invisible.
        if (changed && carousel.overlayVisible)
            carousel.open();
    }

    // ── Applying a pick ───────────────────────────────────────────────────────

    function applyPick(fullPath, screenName) {
        if (!fullPath)
            return;

        const path = root.expandPath(fullPath);
        const args = ["img"];

        // Without -o, awww displays the image on every output.
        if (root.cfg.applyToAllMonitors !== true && screenName)
            args.push("-o", screenName);

        const type = String(root.cfg.transitionType ?? "").trim();
        if (type) {
            args.push("--transition-type", type);
            const pos = String(root.cfg.transitionPos ?? "").trim();
            if (pos)
                args.push("--transition-pos", pos);
        }
        const duration = String(root.cfg.transitionDuration ?? "").trim();
        if (duration)
            args.push("--transition-duration", duration);
        const fps = String(root.cfg.transitionFps ?? "").trim();
        if (fps)
            args.push("--transition-fps", fps);

        args.push(path);
        Quickshell.execDetached(["awww"].concat(args));

        // Mirror the pick into memory right away so the next open highlights the
        // new image even if `awww query` would still answer with the old one.
        if (root.cfg.applyToAllMonitors === true || !screenName) {
            const all = { "": path };
            for (let i = 0; i < Quickshell.screens.length; i++)
                all[Quickshell.screens[i].name] = path;
            root.currentWallpaperByScreen = all;
        } else {
            const next = Object.assign({}, root.currentWallpaperByScreen);
            next[screenName] = path;
            root.currentWallpaperByScreen = next;
        }
    }

    // ── Focused output ────────────────────────────────────────────────────────

    function findScreen(name) {
        if (!name)
            return null;
        for (const screen of Quickshell.screens) {
            if (screen.name === name)
                return screen;
        }
        return null;
    }

    function getFocusedScreen(hint) {
        const byHint = root.findScreen(hint);
        if (byHint)
            return byHint;

        // Hyprland: the focused monitor is tracked live, no subprocess needed.
        // Off Hyprland this is simply null.
        const hypr = Hyprland.focusedMonitor;
        if (hypr) {
            const screen = root.findScreen(hypr.name);
            if (screen)
                return screen;
        }

        // Generic fallback: whichever output holds the pointer. Older
        // Quickshells lack cursorPos; the property access is then undefined.
        const pos = Quickshell.cursorPos;
        if (pos !== undefined) {
            for (const screen of Quickshell.screens) {
                if (pos.x >= screen.x && pos.x < screen.x + screen.width
                    && pos.y >= screen.y && pos.y < screen.y + screen.height)
                    return screen;
            }
        }

        return Quickshell.screens[0] ?? null;
    }

    // ── The carousel ──────────────────────────────────────────────────────────

    Carousel {
        id: carousel

        wlrNamespace: "wallpaperCarousel"
        cfg: root.cfg

        getFocusedScreen: hint => root.getFocusedScreen(hint)

        defaultWallpaperFolder: root.defaultWallpaperFolderFor(carousel.overlayScreen?.name ?? "")

        // Pre-scan the other outputs' directories so per-monitor browsing does
        // not re-read the disk.
        extraDirectories: {
            const browsing = carousel.defaultWallpaperFolder;
            const dirs = [];
            for (const name in (root.cfg.monitorDirectories ?? {})) {
                const dir = root.monitorDirectory(name);
                if (dir && dir !== browsing && dirs.indexOf(dir) < 0)
                    dirs.push(dir);
            }
            return dirs;
        }

        hasWallpaperConfigured: root.cfg.wallpaperDirectory !== ""
            || Object.values(root.currentWallpaperByScreen).some(path => !!path)
            || Object.keys(root.cfg.monitorDirectories ?? {}).length > 0

        currentWallpaperPath: {
            const name = carousel.overlayScreen?.name ?? "";
            return root.currentWallpaperByScreen[name] ?? root.currentWallpaperByScreen[""] ?? "";
        }

        shellSettingsHint: "Set wallpaperDirectory in\n" + root.configPath

        onWallpaperPicked: (fullPath, screenName) => root.applyPick(fullPath, screenName)

        onOverlayVisibleChanged: {
            if (carousel.overlayVisible)
                root.refreshWallpaperState();
        }
    }

    // ── Host plumbing IPC ─────────────────────────────────────────────────────
    // Kept on its own target, separate from Carousel's user-facing
    // "wallpaperCarousel" handler, so scripts and probes never collide with a
    // user command.

    IpcHandler {
        target: "wallpaperCarouselHost"

        function ping(): string {
            return "ok";
        }

        function quit(): string {
            Qt.quit();
            return "quitting";
        }

        // Scriptable wallpaper set: `qs -p <dir> ipc call wallpaperCarouselHost apply <path>`.
        function apply(path: string): string {
            root.applyPick(path, root.getFocusedScreen("")?.name ?? "");
            return "applied";
        }
    }

    Component.onCompleted: {
        root.refreshWallpaperState();
        console.info("WallpaperCarousel: standalone daemon loaded — 'qs -p <dir> ipc call wallpaperCarousel toggle' to open");
    }
}
