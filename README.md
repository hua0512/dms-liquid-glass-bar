# ✨ Liquid Glass Bar

**Give your DankMaterialShell bar the macOS Tahoe "Liquid Glass" look.**

Your bar becomes a clear glass capsule. Its curved edges bend and magnify the wallpaper behind it, light catches the rim, and a soft shadow lifts it off the desktop. It's real refraction, not just blur.

## Why you'll like it

- 🫧 **Real glass, not just blur.** The edges bend the wallpaper like a thick pane of glass.
- 🌗 **Always readable.** Like the macOS menu bar, text and icons turn white over dark wallpapers and dark over light ones, in both light and dark mode.
- 🖼️ **Follows your wallpaper.** Change the wallpaper or switch between light and dark mode and the glass updates instantly.
- 🎚️ **Make it yours.** Sliders for refraction, frost, highlights, tint, shadow and more.
- 🔋 **Battery friendly.** Nothing animates in the background. It only redraws when something changes.

## Install

```sh
git clone https://github.com/hua0512/dms-liquid-glass-bar ~/.config/DankMaterialShell/plugins/liquidGlassBar
dms ipc call plugins enable liquidGlassBar
```

Then let the glass shine through:

1. Open **Settings → Bar → Appearance**, set the bar's **transparency to 0** and turn its **border off**.
2. **On niri**, turn off the compositor's own blur for the bar by adding this to `~/.config/niri/config.kdl`:

   ```kdl
   layer-rule {
       match namespace="^dms:bar$"
       background-effect {
           blur false
       }
   }
   ```

That's it.

## Make it yours

Open **Settings → Plugins → Liquid Glass Bar** and adjust:

| Setting | What it does |
|---|---|
| **Frost** | Clear glass, or soft and milky |
| **Refraction** | How strongly the edges bend the wallpaper |
| **Edge lensing** | *Magnify* (like a lens) or *Wrap* (the edge curls in what's beyond it) |
| **Rim highlight** | How bright the light on the edge is |
| **Shape** | Rounded *capsule*, or follow your bar's own corners |
| **Saturation** | Colour boost of the wallpaper behind the glass |
| **Chromatic fringe** | A subtle rainbow at the very edge |
| **Tint colour / strength** | Tint the glass white, black or in your theme colours |
| **Legibility scrim** | A faint shade behind text over busy wallpapers |
| **Drop shadow** | Lift the bar off the desktop |
| **Adaptive text colour** | Turn off to keep your theme's text colour |

You can also change settings from a script or a keybind:

```sh
dms ipc call liquidGlass set frost 60
```

## Good to know

- **Requirements:** DankMaterialShell / Dux Shell **2.1 or newer** with a normal docked bar (island mode isn't supported). Made and tested on **niri**.
- **Only the wallpaper is bent.** A floating window behind the bar shows through clearly instead.
- **Video wallpapers** show a still frame.
- **DMS updates may break it.** The plugin hooks into DMS's bar, so a major DMS update could break it. If that happens, the glass simply doesn't appear and nothing else breaks. Please [open an issue](https://github.com/hua0512/dms-liquid-glass-bar/issues).

## Turn it off

```sh
dms ipc call plugins disable liquidGlassBar
```

Then bring back your bar's transparency and border in **Settings → Bar → Appearance**.

<details>
<summary><b>How it works (for the curious)</b></summary>

A desktop shell can't see what's behind it, and niri can only blur. But a docked bar reserves its own strip of the screen, so the only thing behind it is your wallpaper.

So the plugin draws your wallpaper under the bar, lined up pixel for pixel, and runs it through a glass shader. The shader traces the bar's rounded outline and bends the image along the rim. It then adds a little colour dispersion, frost, a highlight and a shadow. Another small shader swaps the bar's text and icons to light or dark colours when the wallpaper calls for it.

**Editing the shaders:** the compiled `.qsb` files are included. After editing a `.frag`, rebuild it with:

```sh
/usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o shaders/liquid_glass.frag.qsb shaders/liquid_glass.frag
```

Then bump the `?v=` number in `LiquidGlassDaemon.qml` (Qt caches shaders), or run `dms restart`.

</details>

## License

[MIT](LICENSE)
