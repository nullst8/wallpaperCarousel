# Wallpaper Carousel

Based on the original wallpaper picker by [ilyamiro](https://github.com/ilyamiro/nixos-configuration).

A standalone [Quickshell](https://quickshell.outfoxxed.me/) wallpaper picker: browse and pick wallpapers from a fullscreen skewed carousel overlay. No shell required — it pairs with [awww](https://github.com/LGFae/swww) (an swww fork) or any swww-compatible daemon.

![screenshot](screenshot.png)

## About

Wallpaper Carousel scans your wallpaper directory and displays all images in an animated 3D-skewed carousel. Navigate with keyboard or mouse, press Enter to apply. Thumbnails are pre-cached in memory at boot for instant opening.

Selecting a wallpaper applies it through `awww img` with a configurable animated transition (`grow` by default), and the carousel re-opens centered on whichever wallpaper is currently active.

https://github.com/user-attachments/assets/39bcde76-7d7b-40c0-a083-3b8961edf10b

## Requirements

- Quickshell ≥ 0.3 (`qs`)
- `awww` (or `swww`) with its daemon running — `awww-daemon &` in your compositor's autostart
- A Wayland compositor with layer-shell support (Hyprland, Niri, sway, …)

Focused-output detection uses Hyprland's IPC when available; elsewhere it falls back to the output under the cursor, then the first output.

## Install

### 1. Copy the shell into your config directory

```sh
cp -r wallpaperCarousel "${XDG_CONFIG_HOME:-$HOME/.config}/wallpaperCarousel"
```

Any stable path works; `~/.config/wallpaperCarousel` is what the examples below assume.

### 2. Autostart the daemon

Hyprland (`hyprland.conf`):

```ini
exec-once = qs -p ~/.config/wallpaperCarousel
```

Hyprland with a Lua config (`hyprland.lua`) — inside your `hl.on("hyprland.start", …)` block:

```lua
hl.exec_cmd("qs -p ~/.config/wallpaperCarousel")
```

Other compositors: run `qs -p ~/.config/wallpaperCarousel` from your session startup (systemd user service, `niri` `spawn-at-startup`, etc.).

### 3. Bind keys

Hyprland (`hyprland.conf`):

```ini
bind = SUPER SHIFT, W, exec, ~/.config/wallpaperCarousel/wallpaper-carousel toggle
bind = SUPER SHIFT, Right, exec, ~/.config/wallpaperCarousel/wallpaper-carousel cycleNext
bind = SUPER SHIFT, Left, exec, ~/.config/wallpaperCarousel/wallpaper-carousel cyclePrevious
```

Hyprland (`hyprland.lua`):

```lua
hl.bind(mainMod .. " + SHIFT + W", hl.dsp.exec_cmd("~/.config/wallpaperCarousel/wallpaper-carousel toggle"))
hl.bind(mainMod .. " + SHIFT + Right", hl.dsp.exec_cmd("~/.config/wallpaperCarousel/wallpaper-carousel cycleNext"))
hl.bind(mainMod .. " + SHIFT + Left", hl.dsp.exec_cmd("~/.config/wallpaperCarousel/wallpaper-carousel cyclePrevious"))
```

Niri and anything else: bind `toggle` / `cycleNext` / `cyclePrevious` as shown in [Usage](#usage).

### 4. Configure (optional)

Copy the example and edit it — the daemon watches the file and applies changes live:

```sh
cp ~/.config/wallpaperCarousel/settings.example.json ~/.config/wallpaperCarousel/settings.json
```

See [Configuration](#configuration) for every key.

### Overlay opacity

The overlay is a layer-shell surface, so Hyprland's window-opacity settings (and window rules) never touch it — it renders at its own alpha. The dimmed backdrop behind the carousel is controlled by the `overlayOpacity` setting: at `100` the backdrop is solid black (fully opaque), lower values dim the desktop through it.

## Configuration

Settings live in `~/.config/wallpaperCarousel/settings.json` and apply live — save the file and the next open reflects them; no restart needed. All keys are optional.

| Key | Default | Description |
| --- | ------- | ----------- |
| `wallpaperDirectory` | `""` | Directory to browse. Empty = follow the current wallpaper's directory. `~` is expanded. |
| `carouselMode` | `"wrap"` | `standard` stops at the edges, `wrap` loops the index, `infinite` shows a seamless repeating view. |
| `applyToAllMonitors` | `true` | Apply picks to every output instead of just the one the overlay is on. |
| `overlayOpacity` | `80` | Opacity of the backdrop behind the carousel (0–100). `100` = fully opaque black. |
| `borderWidth` | `3` | Width of the skewed border around thumbnails. |
| `cornerRadius` | `0` | Corner radius of thumbnails. `0` disables rounding. |
| `itemWidth` / `itemHeight` | `300` / `420` | Thumbnail size. |
| `selectedScale` | `108` | Size of the centered tile relative to the others (%). |
| `expandSelected` | `false` | Widen the centered tile to reveal more of the image. |
| `expandMultiplier` | `120` | Width multiplier for the expanded tile (%). |
| `enableHoldExpand` | `false` | Dwell on a tile for a large immersive preview. |
| `holdExpandRatio` | `35` | Screen coverage of the hold preview (%). |
| `holdDelay` | `1500` | Dwell time before the hold preview activates (ms). |
| `cacheSize` | `30` | Wallpapers to pre-cache around the current selection. Lower to save memory. |
| `transitionType` | `"grow"` | awww transition on pick: `simple`, `fade`, `wipe`, `wave`, `grow`, `outer`, `random`, … |
| `transitionPos` | `"center"` | Origin for `grow`/`outer` (e.g. `0.5,0.3`). |
| `transitionDuration` | *(daemon default)* | Transition length in seconds, e.g. `1`. |
| `transitionFps` | *(daemon default)* | Transition frame rate. |
| `monitorDirectories` | `{}` | Per-output directories, e.g. `{ "DP-1": "~/walls-wide" }`. Each output browses its own directory; the others are pre-cached. |

## Usage

**Keyboard** (overlay open): `←` / `→` (or `h` / `l`) to navigate, `Enter` to apply, `Ctrl+F` to search by filename, `Escape` to close. Click a tile to apply, click the backdrop to close, hover to preview, hold on a tile for the immersive preview (if enabled).

**IPC** — every command works as
`qs -p ~/.config/wallpaperCarousel ipc call wallpaperCarousel <command>`,
or shorter via the bundled shim (`./wallpaper-carousel <command>`):

| Command | Description |
| ------- | ----------- |
| `toggle` | Open or close the overlay |
| `open` / `close` | Open / close the overlay |
| `cycleNext` / `cyclePrevious` | Open (if closed) and highlight next / previous wallpaper |
| `toggleOn <output>` etc. | Screen-targeted variants (`openOn`, `closeOn`, `toggleOn`, `cycleNextOn`, `cyclePreviousOn`) |

Host plumbing lives under the `wallpaperCarouselHost` target: `ping`, `quit`, and `apply <path>` to set a wallpaper from scripts.

## Example Compositor Keybindings

### Hyprland

In `hyprland.conf`:

```ini
bind = SUPER, W, exec, qs -p ~/.config/wallpaperCarousel ipc call wallpaperCarousel toggle
bind = SUPER SHIFT, Right, exec, qs -p ~/.config/wallpaperCarousel ipc call wallpaperCarousel cycleNext
bind = SUPER SHIFT, Left, exec, qs -p ~/.config/wallpaperCarousel ipc call wallpaperCarousel cyclePrevious
```

### Niri

In `~/.config/niri/config.kdl`:

```kdl
binds {
    Mod+W { spawn "qs" "-p" "~/.config/wallpaperCarousel" "ipc" "call" "wallpaperCarousel" "toggle"; }
    Mod+Shift+Right { spawn "qs" "-p" "~/.config/wallpaperCarousel" "ipc" "call" "wallpaperCarousel" "cycleNext"; }
    Mod+Shift+Left { spawn "qs" "-p" "~/.config/wallpaperCarousel" "ipc" "call" "wallpaperCarousel" "cyclePrevious"; }
}
```

## Notes

- If the awww daemon is not running when the carousel starts, it attempts to launch `awww-daemon` once.
- Wallpapers changed by other tools are picked up the next time the overlay opens (the daemon is queried for the current wallpaper per output).
- A `settings.json` created after startup is detected within a couple of seconds.
- Do not run this alongside a shell that manages wallpapers (DMS, Noctalia, …) — pick one wallpaper manager.

## Credits

Original wallpaper picker by [ilyamiro](https://github.com/ilyamiro/nixos-configuration).
