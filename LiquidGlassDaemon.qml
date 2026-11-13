import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Puts a window under each DMS bar (Bottom layer, or Background on niri) and renders the wallpaper
// behind the bar's shape through a liquid-glass shader. The bar sits on the Top layer, so its
// widgets stay on top.
// Everything is static: the window only repaints when wallpaper, bar geometry or settings change,
// plus briefly while the pointer moves over the bar or the bar shows or hides.
PluginComponent {
    id: root

    function setting(key, fallback) {
        const v = pluginData ? pluginData[key] : undefined;
        if (v === undefined || v === null || v === "")
            return fallback;
        const n = Number(v);
        return isNaN(n) ? fallback : n;
    }

    readonly property real refraction: setting("refraction", 70) / 100
    readonly property real rimHighlight: setting("rimHighlight", 70) / 100
    readonly property real frost: setting("frost", 50) / 100
    readonly property real saturation: setting("saturation", 108) / 100
    readonly property real tintStrength: setting("tintStrength", 0) / 100
    readonly property real dispersion: setting("dispersion", 15) / 100
    readonly property real scrim: setting("contrast", 50) / 100
    readonly property real shadow: setting("shadow", 50) / 100
    // Average wallpaper colour mixed into the glass, so it picks up its surroundings.
    readonly property real contentTint: setting("contentTint", 30) / 100
    // A soft light that follows the pointer over the bar.
    readonly property bool hoverGlow: pluginData?.hoverGlow ?? true
    // Glass materializes and dematerializes when the bar shows or hides.
    readonly property bool showHideAnimation: pluginData?.showHideAnimation ?? true
    // Bend the moving picture of a video wallpaper instead of its still frame (decodes it again).
    readonly property bool liveVideo: pluginData?.liveVideo ?? false
    // Frame rate of the live video glass: caps both the frames shown and the glass redraws.
    readonly property int liveFps: [15, 24, 30].indexOf(setting("liveFps", 24)) >= 0 ? setting("liveFps", 24) : 24
    // Re-colour the bar's widgets light or dark to suit what is behind the bar (like the macOS
    // menu bar), independent of the global light/dark mode.
    readonly property bool adaptiveForeground: pluginData?.adaptiveForeground ?? true
    readonly property string tintMode: pluginData?.tintMode ?? "auto"
    readonly property string lensMode: pluginData?.lensMode ?? "magnify"
    // "capsule" draws fully rounded ends inside the bar's body; "bar" follows the bar's own corners.
    readonly property string shapeMode: pluginData?.shape ?? "capsule"

    // Canvas channels are bytes: share their linear-light values across probes and bars.
    readonly property var linearChannel: {
        const values = [];
        for (let i = 0; i < 256; i++) {
            const v = i / 255;
            values.push(v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4));
        }
        return values;
    }

    onShapeModeChanged: shapeChanged()
    signal shapeChanged

    readonly property color tintColor: {
        switch (tintMode) {
        case "white":
            return "#ffffff";
        case "black":
            return "#000000";
        case "surface":
            return Theme.surface;
        case "primary":
            return Theme.primary;
        default:
            return SessionData.isLightMode ? "#ffffff" : "#101014";
        }
    }

    readonly property var barWindows: {
        const out = [];
        const items = BarWidgetService.dankBarItems;
        for (const id in items) {
            const instances = items[id]?.barVariants?.instances ?? [];
            for (let i = 0; i < instances.length; i++) {
                if (instances[i] && !instances[i].isIsland)
                    out.push(instances[i]);
            }
        }
        return out;
    }

    function barKey(b) {
        return (b?.screen?.name ?? "") + "|" + (b?.barConfig?.id ?? "");
    }

    // DMS rebuilds a bar's window whenever the bar shows or hides. The glass window is keyed by
    // output and bar instead, so it outlives those rebuilds: it keeps its textures and state,
    // follows the new bar window, and can dematerialize in place while the bar goes away.
    readonly property var liveKeys: {
        const keys = [];
        for (const b of barWindows) {
            const k = barKey(b);
            if (keys.indexOf(k) < 0)
                keys.push(k);
        }
        return keys;
    }
    // New bars get a glass window at once; a bar that disappears keeps it a little longer, since
    // during a rebuild DMS briefly has no window for it at all.
    property var barKeys: []
    onLiveKeysChanged: {
        const missing = liveKeys.filter(k => barKeys.indexOf(k) < 0);
        if (missing.length > 0)
            barKeys = barKeys.concat(missing);
        if (barKeys.some(k => liveKeys.indexOf(k) < 0))
            keyPrune.restart();
    }
    Component.onCompleted: {
        barKeys = liveKeys.slice();
        console.info("liquidGlassBar: started");
    }

    // When an output goes away DMS drops its wallpaper window, and its video starts over when the
    // output comes back: forget that output's video clock.
    Connections {
        target: Quickshell
        function onScreensChanged() {
            root.checkStacking();
            const svc = root.pluginService;
            const vars = svc?.globalVars?.[root.pluginId] ?? {};
            const names = Quickshell.screens.map(s => s.name);
            for (const k in vars) {
                const m = /^video(Clock|Seen):(.*)$/.exec(k);
                if (m && vars[k] !== null && names.indexOf(m[2]) < 0)
                    svc.setGlobalVar(root.pluginId, k, null);
            }
        }
    }

    // On niri the glass shares the Background layer with DMS's wallpaper, and within a layer the
    // surface mapped last is drawn on top. The glass normally maps after the wallpaper, but DMS can
    // map its wallpaper window again (for instance when an output comes back), which would hide
    // the glass behind it; at startup it maps the wallpaper only once the picture has loaded, which
    // can also be after the glass. niri lists layer surfaces in mapping order, so after the glass
    // maps or outputs change, check that order a few times (backing off) and map any glass window
    // that ended up below a wallpaper again.
    function checkStacking() {
        if (!CompositorService.isNiri)
            return;
        stackCheck.round = 0;
        stackCheck.interval = 1000;
        stackCheck.restart();
    }
    Timer {
        id: stackCheck
        property int round: 0
        onTriggered: {
            if (stackQuery.running) {
                restart();
                return;
            }
            stackQuery.running = true;
            if (++round < 3) {
                interval *= 4;
                restart();
            }
        }
    }
    Process {
        id: stackQuery
        command: ["niri", "msg", "--json", "layers"]
        stdout: StdioCollector {
            id: stackOut
        }
        onExited: code => {
            if (code !== 0)
                return;
            let layers;
            try {
                layers = JSON.parse(stackOut.text);
            } catch (e) {
                return;
            }
            // Outputs where some wallpaper surface was mapped after the glass.
            const buried = {};
            const glassSeen = {};
            for (const l of layers ?? []) {
                if (l.layer !== "Background")
                    continue;
                if (l.namespace === "dms:liquid-glass")
                    glassSeen[l.output] = true;
                else if (l.namespace === "quickshell" && glassSeen[l.output])
                    buried[l.output] = true;
            }
            for (const w of glassWindows.instances) {
                if (w?.screen && buried[w.screen.name]) {
                    console.info("liquidGlassBar: glass was below the wallpaper on", w.screen.name, "- mapping it again");
                    w.restack();
                }
            }
        }
    }

    // Per output, the bar window checking its video clock right now ({key, at}), so two bars on
    // one output never check (and correct) the same clock at once.
    property var checkOwners: ({})
    // Clip folder each glass window is using, kept when the cache is pruned.
    property var clipsInUse: ({})

    Timer {
        id: keyPrune
        interval: 2000
        onTriggered: root.barKeys = root.barKeys.filter(k => root.liveKeys.indexOf(k) >= 0)
    }

    function findBar(key) {
        for (const b of barWindows) {
            if (barKey(b) === key)
                return b;
        }
        return null;
    }

    Variants {
        id: glassWindows
        model: root.barKeys

        delegate: PanelWindow {
            id: win

            required property string modelData
            readonly property var bar: root.findBar(modelData)
            onBarChanged: {
                capturePlacement();
                retryAttach.attempts = 0;
                Qt.callLater(win.attach);
            }
            function capturePlacement() {
                if (!bar)
                    return;
                lastPlacement = {
                    "top": bar.anchors.top,
                    "bottom": bar.anchors.bottom,
                    "left": bar.anchors.left,
                    "right": bar.anchors.right,
                    "mt": bar.margins.top,
                    "mb": bar.margins.bottom,
                    "ml": bar.margins.left,
                    "mr": bar.margins.right,
                    "w": bar.width,
                    "h": bar.height,
                    "vertical": bar.isVertical ?? false,
                    "screen": bar.screen
                };
            }
            // Where the bar was, so the glass stays put while DMS swaps the bar's window.
            property var lastPlacement: ({
                    "top": false,
                    "bottom": true,
                    "left": true,
                    "right": true,
                    "mt": 0,
                    "mb": 0,
                    "ml": 0,
                    "mr": 0,
                    "w": 1,
                    "h": 1,
                    "vertical": false,
                    "screen": null
                })

            // ---- bar shape tracking -------------------------------------------------------

            property Item surf: null
            property Item surfBody: null
            // DBarContent: the item holding every widget of the bar.
            property Item fgTarget: null
            property var geo: ({
                    "valid": false
                })
            property var _watched: []

            function isBarSurface(item) {
                return item.leadingWing !== undefined && item.trailingWing !== undefined && item.shapeTarget !== undefined;
            }

            function isBarContent(item) {
                return item.overflowPlan !== undefined && item.leadingImplicitSize !== undefined && item.leftWidgetsModel !== undefined;
            }

            function findItem(item, depth, pred) {
                if (!item || depth > 14)
                    return null;
                if (pred(item))
                    return item;
                const kids = item.children;
                for (let i = 0; i < kids.length; i++) {
                    const found = findItem(kids[i], depth + 1, pred);
                    if (found)
                        return found;
                }
                return null;
            }

            function watch(sig) {
                if (!sig)
                    return;
                sig.connect(win.scheduleUpdate);
                _watched.push(sig);
            }

            function detach() {
                for (const sig of _watched) {
                    try {
                        sig.disconnect(win.scheduleUpdate);
                    } catch (e) {}
                }
                _watched = [];
                setRemap(false);
                detachHover();
                fgTarget = null;
                surf = null;
                surfBody = null;
            }

            function attach() {
                detach();
                const ci = bar?.contentItem;
                const s = ci ? findItem(ci, 0, isBarSurface) : null;
                if (!s) {
                    geo = {
                        "valid": false
                    };
                    setShown(false);
                    retryAttach.again();
                    return;
                }
                let b = null;
                for (let i = 0; i < s.children.length; i++) {
                    if (s.children[i].motion !== undefined && s.children[i].topLeftRadius !== undefined) {
                        b = s.children[i];
                        break;
                    }
                }
                if (!b) {
                    retryAttach.again();
                    return;
                }
                retryAttach.attempts = 0;
                surf = s;
                surfBody = b;
                fgTarget = findItem(ci, 0, isBarContent);
                setRemap(remapActive);
                attachHover();

                for (const sig of [b.xChanged, b.yChanged, b.widthChanged, b.heightChanged, b.topLeftRadiusChanged, b.topRightRadiusChanged, b.bottomLeftRadiusChanged, b.bottomRightRadiusChanged, b.visibleChanged])
                    watch(sig);
                for (const w of [s.leadingWing, s.trailingWing]) {
                    for (const sig of [w.xChanged, w.yChanged, w.widthChanged, w.heightChanged, w.visibleChanged, w.cornerChanged])
                        watch(sig);
                }
                // Every ancestor up to the window: position, size, visibility, opacity and slide transforms.
                for (let it = s; it && it !== ci; it = it.parent) {
                    for (const sig of [it.xChanged, it.yChanged, it.widthChanged, it.heightChanged, it.visibleChanged, it.opacityChanged])
                        watch(sig);
                    const tf = it.transform;
                    for (let i = 0; tf && i < tf.length; i++) {
                        watch(tf[i].xChanged);
                        watch(tf[i].yChanged);
                    }
                }
                watch(s.parentChanged);
                updateGeometry();
            }

            // Bar config edits (including show/hide) usually keep the same items; only rebuild the
            // hooks when DMS really replaced them.
            function reattachIfNeeded() {
                const ci = bar?.contentItem;
                if (!surf || findItem(ci, 0, isBarSurface) !== surf || findItem(ci, 0, isBarContent) !== fgTarget)
                    attach();
                else
                    scheduleUpdate();
            }

            // The glass last seen at rest (output coordinates), drawn while it dematerializes after
            // the bar hid; `shown` is whether the bar is on screen and at rest right now.
            property var lastShown: null
            property var ghost: null
            property bool shown: false
            readonly property var drawGeo: {
                if (geo.valid || !ghost || appear <= 0)
                    return geo;
                return {
                    "valid": true,
                    "body": Qt.vector4d(ghost.x - winX, ghost.y - winY, ghost.w, ghost.h),
                    "radii": ghost.radii,
                    "thickness": ghost.thickness,
                    "wingA": null,
                    "wingB": null
                };
            }

            function scheduleUpdate() {
                Qt.callLater(win.updateGeometry);
            }

            // ---- adaptive foreground ------------------------------------------------------

            // Which foreground reads better over the wallpaper behind the text band of the glass:
            // the 10th-percentile contrast of light and of dark text, measured on the CPU from a
            // tiny downsample whenever the wallpaper or the bar geometry changes. Using a low
            // percentile rather than the mean keeps light text off a bar with bright patches.
            readonly property bool needsProbe: root.adaptiveForeground || root.contentTint > 0
            onNeedsProbeChanged: requestProbe()
            property color avgColor: "transparent"
            property real lightScore: -1
            property real darkScore: -1
            property bool wantLightFg: !Theme.isLightMode
            readonly property bool measured: lightScore >= 0
            readonly property bool themeLightFg: (0.2126 * Theme.widgetTextColor.r + 0.7152 * Theme.widgetTextColor.g + 0.0722 * Theme.widgetTextColor.b) > 0.5
            readonly property bool remapActive: root.adaptiveForeground && geo.valid && measured && wantLightFg !== themeLightFg && fgTarget !== null
            readonly property bool fgLight: root.adaptiveForeground && measured ? wantLightFg : themeLightFg

            function chooseForeground(light, dark) {
                const first = lightScore < 0;
                lightScore = light;
                darkScore = dark;
                // Hysteresis: only switch when the other choice is clearly better.
                if (first)
                    wantLightFg = light > dark;
                else if (wantLightFg && dark > light * 1.2)
                    wantLightFg = false;
                else if (!wantLightFg && light > dark * 1.2)
                    wantLightFg = true;
            }
            onRemapActiveChanged: setRemap(remapActive)

            function setRemap(on) {
                const t = fgTarget;
                if (!t)
                    return;
                try {
                    if (on) {
                        // Leave the item alone if DMS ever layers it itself.
                        if (t.layer.enabled && t.layer.effect !== remapEffect)
                            return;
                        t.layer.effect = remapEffect;
                        t.layer.enabled = true;
                    } else if (t.layer.effect === remapEffect) {
                        t.layer.enabled = false;
                        t.layer.effect = null;
                    }
                } catch (e) {
                    console.warn("liquidGlassBar: could not re-colour the bar:", e);
                }
            }

            function requestProbe() {
                // A stable callback lets Qt.callLater coalesce requests from the same change.
                if (needsProbe)
                    Qt.callLater(win.paintProbe);
            }

            function paintProbe() {
                if (needsProbe)
                    lumaProbe.requestPaint();
            }

            function vec(c) {
                const q = Qt.color(c);
                return Qt.vector4d(q.r, q.g, q.b, 1);
            }

            // Same roles in the opposite light/dark palette.
            readonly property var otherPalette: Theme.wallpaperThemeData(!Theme.isLightMode) ?? ({})
            readonly property color dstTextColor: (SettingsData.widgetColorMode === "colorful" ? otherPalette.primary : otherPalette.surfaceText) ?? (themeLightFg ? "#1b1b1f" : "#e4e1e6")
            readonly property color dstVariantColor: otherPalette.surfaceVariantText ?? dstTextColor
            readonly property color dstPrimaryColor: otherPalette.primary ?? Theme.primary
            readonly property color dstFillColor: otherPalette.surfaceContainer ?? (themeLightFg ? "#f3eff4" : "#1f1f23")

            Component {
                id: remapEffect

                ShaderEffect {
                    property var source: null
                    property vector4d srcText: win.vec(Theme.widgetTextColor)
                    property vector4d srcVariant: win.vec(Theme.surfaceVariantText)
                    property vector4d srcPrimary: win.vec(Theme.primary)
                    property vector4d srcFill: win.vec(Theme.widgetBaseBackgroundColor)
                    property vector4d dstText: win.vec(win.dstTextColor)
                    property vector4d dstVariant: win.vec(win.dstVariantColor)
                    property vector4d dstPrimary: win.vec(win.dstPrimaryColor)
                    property vector4d dstFill: win.vec(win.dstFillColor)
                    property real tolerance: 0.02
                    property real fillAlpha: SettingsData.barWidgetTransparency(win.bar?.barConfig)
                    fragmentShader: Qt.resolvedUrl("shaders/fg_remap.frag.qsb") + "?v=11"
                }
            }

            Timer {
                id: probeSettle
                interval: 400
                onTriggered: {
                    if (win.revealed && win.geo.valid)
                        win.requestProbe();
                }
            }

            Timer {
                id: probeRetry
                property int attempts: 0
                interval: 150
                onTriggered: win.paintProbe()
            }

            // With live video glass the picture keeps changing, so the probe re-measures a small grab
            // of it every few seconds instead (never per frame); hysteresis in chooseForeground keeps
            // the text colour from flickering.
            readonly property bool liveProbing: liveVideo.item?.playing === true && shown && needsProbe
            property var grabResult: null
            Timer {
                id: liveProbe
                interval: 4000
                repeat: true
                running: win.liveProbing
                onTriggered: wallRoot.grabToImage(r => {
                    win.grabResult = r;
                }, Qt.size(384, Math.max(1, Math.round(384 * win.screenH / Math.max(1, win.screenW)))))
            }
            onLiveProbingChanged: {
                if (!liveProbing)
                    grabResult = null;
            }
            Image {
                id: grabImg
                width: 1
                height: 1
                opacity: 0
                source: win.grabResult?.url ?? ""
                asynchronous: true
                cache: false
                onStatusChanged: {
                    if (status === Image.Ready)
                        win.requestProbe();
                }
            }
            readonly property var probeSource: grabImg.status === Image.Ready && grabResult ? grabImg : probeImg

            // A small copy of the wallpaper (native aspect) just for measuring.
            Image {
                id: probeImg
                width: 1
                height: 1
                opacity: 0
                source: win.needsProbe ? win.wallpaperUrl : ""
                asynchronous: true
                cache: false
                sourceSize.width: 384
                onStatusChanged: {
                    if (status === Image.Ready) {
                        probeRetry.stop();
                        probeRetry.attempts = 0;
                        lumaProbe.lastProbeKey = "";
                        win.requestProbe();
                    }
                }
            }

            Canvas {
                id: lumaProbe
                // Whole wallpaper, drawn at the probe image's aspect.
                width: 384
                height: Math.max(1, Math.round(384 * (win.probeSource.implicitHeight || 216) / (win.probeSource.implicitWidth || 384)))
                opacity: 0
                renderStrategy: Canvas.Immediate
                renderTarget: Canvas.Image
                property string lastProbeKey: ""

                onPaint: {
                    if (!win.needsProbe)
                        return;
                    const ctx = getContext("2d");
                    if (!ctx)
                        return;
                    // Relative luminance (linear) and WCAG contrast against light and dark text.
                    const lin = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
                    const lumY = (r, g, b) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
                    const lightY = 0.75, darkY = 0.012;
                    if (win.wallpaperIsColor) {
                        const c = Qt.color(win.wallpaper);
                        win.avgColor = c;
                        const y = lumY(c.r, c.g, c.b);
                        win.chooseForeground((lightY + 0.05) / (y + 0.05), (y + 0.05) / (darkY + 0.05));
                        return;
                    }
                    const g = win.geo;
                    // Only measure the bar at rest on screen, never mid-slide or while hidden.
                    const src = win.probeSource;
                    // A grab of the live picture is already laid out like the screen.
                    const grabbed = src === grabImg;
                    if (src.status !== Image.Ready || !g.valid || !win.revealed || probeSettle.running)
                        return;
                    const cw = width, ch = height;
                    const W = win.screenW, H = win.screenH;
                    const probeKey = JSON.stringify([win.wallpaperUrl, grabbed ? String(grabImg.source) : "", wallImg.fillMode, W, H, win.pxRatio, cw, ch,
                        win.winX + g.body.x, win.winY + g.body.y, g.body.z, g.body.w]);
                    if (probeKey === lastProbeKey)
                        return;
                    ctx.clearRect(0, 0, cw, ch);
                    // Qt's canvas scales item sources by the device pixel ratio; compensate, and fall
                    // back to the plain size if the image then doesn't cover the canvas.
                    ctx.drawImage(src, 0, 0, cw / win.pxRatio, ch / win.pxRatio);
                    if (ctx.getImageData(Math.floor(cw * 0.9), Math.floor(ch * 0.9), 1, 1).data[3] === 0) {
                        ctx.clearRect(0, 0, cw, ch);
                        ctx.drawImage(src, 0, 0, cw, ch);
                    }
                    // Where the output sits on the canvas, using the wallpaper's fill mode.
                    let kx = W / cw, ky = H / ch;
                    if (grabbed) {
                        // already screen-shaped
                    } else if (wallImg.fillMode === Image.PreserveAspectCrop)
                        kx = ky = Math.max(kx, ky);
                    else if (wallImg.fillMode === Image.PreserveAspectFit || wallImg.fillMode === Image.Pad)
                        kx = ky = Math.min(kx, ky);
                    // The text band: the middle 60% of the glass body.
                    const bx = win.winX + g.body.x, by = win.winY + g.body.y + g.body.w * 0.2;
                    let x0 = Math.floor((bx - W / 2) / kx + cw / 2), y0 = Math.floor((by - H / 2) / ky + ch / 2);
                    let x1 = Math.ceil((bx + g.body.z - W / 2) / kx + cw / 2), y1 = Math.ceil((by + g.body.w * 0.6 - H / 2) / ky + ch / 2);
                    x0 = Math.max(0, Math.min(cw - 1, x0));
                    y0 = Math.max(0, Math.min(ch - 1, y0));
                    x1 = Math.max(x0 + 1, Math.min(cw, x1));
                    y1 = Math.max(y0 + 1, Math.min(ch, y1));
                    const data = ctx.getImageData(x0, y0, x1 - x0, y1 - y0).data;
                    const linear = root.linearChannel;
                    const luminances = [];
                    for (let i = 0; i < data.length; i += 4) {
                        if (data[i + 3] === 0)
                            continue;
                        luminances.push(0.2126 * linear[data[i]] + 0.7152 * linear[data[i + 1]] + 0.0722 * linear[data[i + 2]]);
                    }
                    if (luminances.length > 0) {
                        probeRetry.attempts = 0;
                        // Average colour of the whole glass body, for the content tint.
                        const by0 = Math.max(0, Math.min(ch - 1, Math.floor((win.winY + g.body.y - H / 2) / ky + ch / 2)));
                        const by1 = Math.max(by0 + 1, Math.min(ch, Math.ceil((win.winY + g.body.y + g.body.w - H / 2) / ky + ch / 2)));
                        const all = ctx.getImageData(x0, by0, x1 - x0, by1 - by0).data;
                        let r = 0, gg = 0, bb = 0, n = 0;
                        for (let i = 0; i < all.length; i += 4) {
                            if (all[i + 3] === 0)
                                continue;
                            r += linear[all[i]];
                            gg += linear[all[i + 1]];
                            bb += linear[all[i + 2]];
                            n++;
                        }
                        const enc = v => v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055;
                        if (n > 0)
                            win.avgColor = Qt.rgba(enc(r / n), enc(gg / n), enc(bb / n), 1);
                        // Dark contrast increases with luminance; light contrast decreases.
                        // One sort gives exactly the same two 10th percentiles as before.
                        luminances.sort((a, b) => a - b);
                        const p10 = Math.floor(luminances.length * 0.1);
                        lastProbeKey = probeKey;
                        win.chooseForeground((lightY + 0.05) / (luminances[luminances.length - 1 - p10] + 0.05),
                            (luminances[p10] + 0.05) / (darkY + 0.05));
                    } else if (probeRetry.attempts < 8) {
                        // The canvas sees a freshly decoded image only from the next frame on.
                        probeRetry.attempts++;
                        probeRetry.restart();
                    }
                }
            }

            function wingGeo(w, ci, body) {
                if (!w || !w.visible || w.width <= 0 || w.height <= 0)
                    return null;
                const q = w.mapToItem(ci, 0, 0);
                const p = Qt.point(q.x + padX, q.y + padY);
                const rx = w.radiusX, ry = w.radiusY;
                let cx = 0, cy = 0;
                switch (w.corner) {
                case "topRight":
                    cx = rx;
                    cy = 0;
                    break;
                case "bottomRight":
                    cx = rx;
                    cy = ry;
                    break;
                case "bottomLeft":
                    cx = 0;
                    cy = ry;
                    break;
                default:
                    cx = 0;
                    cy = 0;
                }
                let r = {
                    "x": p.x,
                    "y": p.y,
                    "w": w.width,
                    "h": w.height
                };
                // Grow the square a little into the body so the union has no seam at the join.
                const ov = 8;
                if (r.y + r.h <= body.y + 0.5)
                    r.h += ov;
                else if (r.y >= body.y + body.h - 0.5) {
                    r.y -= ov;
                    r.h += ov;
                } else if (r.x + r.w <= body.x + 0.5)
                    r.w += ov;
                else if (r.x >= body.x + body.w - 0.5) {
                    r.x -= ov;
                    r.w += ov;
                }
                return {
                    "rect": Qt.vector4d(r.x, r.y, r.w, r.h),
                    "disc": Qt.vector4d(p.x + cx, p.y + cy, Math.max(rx, 0.01), Math.max(ry, 0.01))
                };
            }

            function updateGeometry() {
                capturePlacement();
                const ci = bar?.contentItem;
                const s = surf, b = surfBody;
                if (!ci || !s || !b) {
                    geo = {
                        "valid": false
                    };
                    setShown(false);
                    return;
                }
                let shown = bar.visible && b.visible;
                for (let it = b; shown && it && it !== ci; it = it.parent) {
                    if (!it.visible || it.opacity <= 0)
                        shown = false;
                }
                const p = b.mapToItem(ci, 0, 0);
                const body = {
                    "x": p.x + padX,
                    "y": p.y + padY,
                    "w": b.width,
                    "h": b.height
                };
                const capsule = root.shapeMode === "capsule";
                const cap = Math.min(body.w, body.h) / 2;
                const onScreen = body.w > 0 && body.h > 0 && body.x < ci.width + padX && body.y < ci.height + padY && body.x + body.w > padX && body.y + body.h > padY;
                geo = {
                    "valid": shown && onScreen,
                    "body": Qt.vector4d(body.x, body.y, body.w, body.h),
                    "radii": capsule ? Qt.vector4d(cap, cap, cap, cap) : Qt.vector4d(b.topLeftRadius, b.topRightRadius, b.bottomRightRadius, b.bottomLeftRadius),
                    "thickness": Math.min(body.w, body.h),
                    "wingA": capsule ? null : wingGeo(s.leadingWing, ci, body),
                    "wingB": capsule ? null : wingGeo(s.trailingWing, ci, body)
                };
                setShown(geo.valid && revealed);
                if (shown) {
                    const bb = geo.body, r = geo.radii, ls = lastShown;
                    // Only a real change, since the live video strip is worked out from it.
                    if (!ls || ls.x !== winX + bb.x || ls.y !== winY + bb.y || ls.w !== bb.z || ls.h !== bb.w || ls.thickness !== geo.thickness || ls.radii.x !== r.x || ls.radii.y !== r.y || ls.radii.z !== r.z || ls.radii.w !== r.w)
                        lastShown = {
                            "x": winX + bb.x,
                            "y": winY + bb.y,
                            "w": bb.z,
                            "h": bb.w,
                            "radii": r,
                            "thickness": geo.thickness
                        };
                    // Measure once the bar has come to rest (not while it slides in or out).
                    if (needsProbe)
                        probeSettle.restart();
                }
            }

            // ---- pointer glow ---------------------------------------------------------------

            // A passive HoverHandler on the bar window reports the pointer; it never takes input.
            // Updates are throttled to ~30 per second and stop as soon as the pointer leaves.
            property var hoverHandler: null
            property point hoverPos: Qt.point(0, 0)
            property point _pendingHover: Qt.point(0, 0)
            property real hoverAmount: 0

            Component {
                id: hoverComp
                HoverHandler {}
            }

            function attachHover() {
                detachHover();
                const ci = bar?.contentItem;
                if (!ci || !root.hoverGlow)
                    return;
                try {
                    const h = hoverComp.createObject(ci);
                    h.pointChanged.connect(win.onHoverPoint);
                    h.hoveredChanged.connect(win.onHoverChanged);
                    hoverHandler = h;
                } catch (e) {
                    console.warn("liquidGlassBar: no pointer glow:", e);
                }
            }

            function detachHover() {
                hoverThrottle.stop();
                hoverFade.stop();
                if (hoverHandler) {
                    hoverHandler.destroy();
                    hoverHandler = null;
                }
                hoverAmount = 0;
            }

            function onHoverPoint() {
                const h = hoverHandler;
                if (!h || !h.hovered)
                    return;
                const p = Qt.point(h.point.position.x + padX, h.point.position.y + padY);
                _pendingHover = p;
                if (!hoverThrottle.running && (hoverPos.x !== p.x || hoverPos.y !== p.y)) {
                    hoverPos = _pendingHover;
                    hoverThrottle.start();
                }
            }

            function onHoverChanged() {
                if (!hoverHandler?.hovered)
                    hoverThrottle.stop();
                hoverFade.to = hoverHandler?.hovered ? 1 : 0;
                hoverFade.restart();
            }

            Timer {
                id: hoverThrottle
                interval: 33
                onTriggered: {
                    if (win.hoverHandler?.hovered && (win.hoverPos.x !== win._pendingHover.x || win.hoverPos.y !== win._pendingHover.y)) {
                        win.hoverPos = win._pendingHover;
                        // Keep the cooldown after a trailing update too, so the next pointer event
                        // cannot immediately repaint again. Stops after at most one quiet timeout.
                        hoverThrottle.restart();
                    }
                }
            }

            NumberAnimation {
                id: hoverFade
                target: win
                property: "hoverAmount"
                duration: 220
                easing.type: Easing.OutCubic
            }

            Connections {
                target: root
                function onHoverGlowChanged() {
                    if (root.hoverGlow)
                        win.attachHover();
                    else
                        win.detachHover();
                }
            }

            // ---- materialize ----------------------------------------------------------------

            // 0..1: the glass fades in while its lensing builds up when the bar appears, and fades
            // out in place (drawn from `ghost`) when it goes. Nothing renders once it settles.
            property real appear: 0
            readonly property bool revealed: bar?.barRevealed ?? false

            function setShown(now) {
                if (now === shown)
                    return;
                shown = now;
                if (!root.showHideAnimation) {
                    appearAnim.stop();
                    ghost = null;
                    appear = now ? 1 : 0;
                    return;
                }
                ghost = now ? null : lastShown;
                appearAnim.to = now ? 1 : 0;
                appearAnim.restart();
            }

            NumberAnimation {
                id: appearAnim
                target: win
                property: "appear"
                duration: 300
                easing.type: Easing.OutCubic
                onFinished: {
                    if (win.appear <= 0)
                        win.ghost = null;
                }
            }

            // If DMS's bar doesn't look as expected (still being built, or changed by an update),
            // look again a few times, backing off, then give up until the bar or its config changes.
            Timer {
                id: retryAttach
                property int attempts: 0
                function again() {
                    if (!win.bar || attempts >= 8)
                        return;
                    interval = Math.min(500 * Math.pow(2, attempts), 8000);
                    attempts++;
                    restart();
                }
                onTriggered: win.attach()
            }

            onSurfChanged: {
                // The surface went away under us (bar rebuilt); find the new one.
                if (!surf && _watched.length > 0)
                    Qt.callLater(win.attach);
            }

            Connections {
                target: win.bar
                function onHeightChanged() {
                    win.scheduleUpdate();
                }
                function onWidthChanged() {
                    win.scheduleUpdate();
                }
                function onVisibleChanged() {
                    win.scheduleUpdate();
                }
                function onBarConfigChanged() {
                    retryAttach.attempts = 0;
                    Qt.callLater(win.reattachIfNeeded);
                }
            }

            Connections {
                target: root
                function onShapeChanged() {
                    win.scheduleUpdate();
                }
            }

            Component.onCompleted: {
                Qt.callLater(updateClock);
                Qt.callLater(refreshStrip);
                attach();
            }
            Component.onDestruction: {
                detach();
                if (root.clipsInUse[modelData] === stripFile)
                    delete root.clipsInUse[modelData];
                for (const name in root.checkOwners) {
                    if (root.checkOwners[name]?.key === modelData)
                        delete root.checkOwners[name];
                }
            }

            // ---- layer surface ------------------------------------------------------------

            screen: bar ? bar.screen : lastPlacement.screen
            color: "transparent"
            // Stays mapped while the bar exists, so showing the bar again needs no new surface;
            // when the glass is hidden nothing is drawn and nothing re-renders.
            // Unmapping is delayed so a bar rebuild doesn't drop the surface (and its textures).
            readonly property bool wantMapped: (surf !== null && (bar?.visible ?? false)) || ghost !== null
            property bool mapped: false
            onWantMappedChanged: {
                if (wantMapped) {
                    unmapDelay.stop();
                    mapped = true;
                } else {
                    unmapDelay.restart();
                }
            }
            Timer {
                id: unmapDelay
                interval: 1500
                onTriggered: win.mapped = win.wantMapped
            }
            onMappedChanged: {
                if (mapped)
                    root.checkStacking();
            }
            // Briefly unmapped to put the surface back on top of its layer (see checkStacking).
            property bool restacking: false
            function restack() {
                if (!mapped || restacking)
                    return;
                restacking = true;
                Qt.callLater(() => {
                    win.restacking = false;
                });
            }
            visible: mapped && !restacking
            exclusionMode: ExclusionMode.Ignore
            // niri draws the Bottom layer inside each workspace, so the glass would slide away on a
            // workspace switch and shrink into the overview while the bar stays put. On the
            // Background layer it can join the wallpaper in the overview backdrop
            // (place-within-backdrop), which never moves; without that rule it acts as before.
            WlrLayershell.layer: CompositorService.isNiri ? WlrLayer.Background : WlrLayer.Bottom
            WlrLayershell.namespace: "dms:liquid-glass"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region {}

            anchors.top: bar ? bar.anchors.top : lastPlacement.top
            anchors.bottom: bar ? bar.anchors.bottom : lastPlacement.bottom
            anchors.left: bar ? bar.anchors.left : lastPlacement.left
            anchors.right: bar ? bar.anchors.right : lastPlacement.right
            margins.top: bar ? bar.margins.top : lastPlacement.mt
            margins.bottom: bar ? bar.margins.bottom : lastPlacement.mb
            margins.left: bar ? bar.margins.left : lastPlacement.ml
            margins.right: bar ? bar.margins.right : lastPlacement.mr
            // The glass window is the bar window plus room for the shadow on the side away from the
            // screen edge; bar coordinates are shifted by (padX, padY) inside it.
            readonly property int shadowRoom: 20
            readonly property bool barVertical: bar ? (bar.isVertical ?? false) : lastPlacement.vertical
            readonly property int padX: barVertical && anchors.right && !anchors.left ? shadowRoom : 0
            readonly property int padY: !barVertical && anchors.bottom && !anchors.top ? shadowRoom : 0
            implicitWidth: Math.max(1, (bar ? bar.width : lastPlacement.w) + (barVertical ? shadowRoom : 0))
            implicitHeight: Math.max(1, (bar ? bar.height : lastPlacement.h) + (barVertical ? 0 : shadowRoom))
            onPadXChanged: scheduleUpdate()
            onPadYChanged: scheduleUpdate()

            readonly property real screenW: screen?.width ?? 0
            readonly property real screenH: screen?.height ?? 0
            readonly property real pxRatio: CompositorService.getScreenScale(screen)
            // Where this window sits on the output, in logical pixels.
            readonly property real winX: anchors.left ? margins.left : anchors.right ? screenW - width - margins.right : Math.round((screenW - width) / 2)
            readonly property real winY: anchors.top ? margins.top : anchors.bottom ? screenH - height - margins.bottom : Math.round((screenH - height) / 2)
            onScreenWChanged: requestProbe()
            onScreenHChanged: requestProbe()
            onPxRatioChanged: requestProbe()
            onWinXChanged: requestProbe()
            onWinYChanged: requestProbe()

            // ---- wallpaper, laid out exactly like DMS's WallpaperBackground -----------------

            readonly property string wallpaper: {
                const _deps = [SessionData.wallpaperPath, SessionData.monitorWallpapers, SessionData.isLightMode, SessionData.perMonitorWallpaper];
                return VideoWallpaperService.imageFor(SessionData.getMonitorWallpaper(screen?.name ?? "") || "");
            }
            readonly property bool wallpaperIsColor: wallpaper.startsWith("#")
            onWallpaperChanged: requestProbe()
            readonly property string wallpaperUrl: {
                if (!wallpaper || wallpaperIsColor)
                    return "";
                if (wallpaper.startsWith("file://"))
                    return wallpaper;
                return "file://" + wallpaper.split('/').map(s => encodeURIComponent(s)).join('/');
            }

            // ---- live video glass -----------------------------------------------------------

            // DMS's own video player lives in its wallpaper window, which a plugin can't reach. So
            // the plugin keeps a clock of where that player should be: it runs while DMS's player
            // runs (DMS pauses it when the screen is locked or off, under a fullscreen window and
            // while niri's overview blurs the wallpaper) and restarts when the video changes. The
            // clock lives in a plugin global, so it survives plugin reloads; it costs nothing
            // but a few bindings when live video glass is off.
            readonly property string sourcePath: {
                const _deps = [SessionData.wallpaperPath, SessionData.monitorWallpapers, SessionData.isLightMode, SessionData.perMonitorWallpaper];
                return SessionData.getMonitorWallpaper(screen?.name ?? "") || "";
            }
            readonly property bool videoWall: VideoWallpaperService.isVideo(sourcePath)
            readonly property bool dmsVideoPlays: videoWall && wallpaper !== "" && !IdleService.isShellLocked && !IdleService.monitorsOff && !(CompositorService.isNiri && SettingsData.blurWallpaperOnOverview && NiriService.inOverview) && !CompositorService.fullscreenToplevelOnScreen(screen)
            // A light/dark switch on niri swaps the wallpaper without DMS's crossfade.
            property bool _immediateChange: false
            onSourcePathChanged: {
                _immediateChange = CompositorService.isNiri && SessionData.isSwitchingMode;
                // A cut for the previous wallpaper is no use any more.
                if (stripCutter.running && stripCutter.forPath !== sourcePath) {
                    stripCutter.aborted = true;
                    stripCutter.running = false;
                }
                Qt.callLater(updateClock);
                Qt.callLater(refreshStrip);
            }
            // Deferred, so the bindings above have all caught up.
            onDmsVideoPlaysChanged: Qt.callLater(updateClock)
            onScreenChanged: Qt.callLater(updateClock)

            function clockKey() {
                return "videoClock:" + (screen?.name ?? "");
            }

            // Clock: {src, base: ms played before `since`, since: when it last started running
            // (null while paused), start: when DMS first plays this video, screen: the output
            // object it plays on, checks: clock checks used (see beginClockCheck), lastCheck}.
            function updateClock() {
                const svc = root.pluginService;
                if (!svc || !screen)
                    return;
                const old = svc.getGlobalVar(root.pluginId, clockKey(), null);
                // Whether this output's wallpaper was already seen this shell session.
                const seenKey = "videoSeen:" + screen.name;
                const seen = svc.getGlobalVar(root.pluginId, seenKey, null) === true;
                if (!seen)
                    svc.setGlobalVar(root.pluginId, seenKey, true);
                const now = Date.now();
                let c = null;
                if (!videoWall) {
                    if (!old)
                        return;
                } else if (!old || old.src !== sourcePath || (old.screen && old.screen !== screen)) {
                    // (A new output object for the same name: DMS made a new player, which starts over.)
                    // A video that was already playing as the shell started began roughly half a
                    // second before plugins load (measured here: 300-550ms, varying per start; the
                    // clock check in ClockCheck.qml then measures it). One we saw DMS switch to
                    // plays after its ~1s crossfade from the still frame, if any.
                    const delay = !seen ? -450 : SessionData.wallpaperTransition === "none" || _immediateChange ? 0 : 1000;
                    c = {
                        "src": sourcePath,
                        "base": 0,
                        "start": now + delay,
                        "since": dmsVideoPlays ? now + delay : null,
                        "screen": screen,
                        "checks": 0,
                        "lastCheck": 0
                    };
                } else if (dmsVideoPlays && old.since === null) {
                    // The crossfade runs even while DMS is paused, so it may be over already.
                    // DMS's player doesn't pause and resume exactly with the clock, and drifts a little
                    // each time it loops: allow one more check on resuming, at most once a minute.
                    const recheck = now - (old.lastCheck ?? 0) > 60000;
                    c = {
                        "src": old.src,
                        "base": old.base,
                        "start": old.start,
                        "since": Math.max(now, old.start),
                        "screen": screen,
                        "checks": recheck ? Math.min(old.checks ?? 0, 1) : (old.checks ?? 0),
                        "lastCheck": old.lastCheck ?? 0
                    };
                } else if (!dmsVideoPlays && old.since !== null) {
                    c = {
                        "src": old.src,
                        "base": old.base + Math.max(0, now - old.since),
                        "start": old.start,
                        "since": null,
                        "screen": screen,
                        "checks": old.checks ?? 0,
                        "lastCheck": old.lastCheck ?? 0
                    };
                } else {
                    return;
                }
                _immediateChange = false;
                svc.setGlobalVar(root.pluginId, clockKey(), c);
            }

            function currentClock() {
                const c = screen ? root.pluginService?.getGlobalVar(root.pluginId, clockKey(), null) : null;
                return c && c.src === sourcePath ? c : null;
            }

            // Where DMS's player should be now (ms), or null without a clock.
            function position() {
                const c = currentClock();
                if (!c)
                    return null;
                const pos = c.base + (c.since !== null ? Math.max(0, Date.now() - c.since) : 0);
                const d = videoInfo?.ms ?? 0;
                return d > 0 ? pos % d : pos;
            }

            // The glass only needs the strip of the video behind the bar, so instead of playing the
            // whole video a second time, ffmpeg cuts that strip out once (cropped, at the chosen frame
            // rate, about one pixel per screen pixel) into a folder of small JPEG frames in ~/.cache, whose
            // frames are then shown in step with the clock. Until it's ready, or without ffmpeg, the
            // glass keeps the still frame.
            readonly property bool liveWanted: root.liveVideo && videoWall
            onLiveWantedChanged: Qt.callLater(refreshStrip)
            // {path, mtime, w, h, ms, fps} of the current video, from ffprobe.
            property var videoInfo: null
            // The clip being played, its source video and where it goes on the output.
            property string stripFile: ""
            property real stripFps: 24
            property int stripFrames: 0
            property var stripSig: null
            property string stripFor: ""
            property rect stripRect: Qt.rect(0, 0, 0, 0)
            property string stripKey: ""
            readonly property bool stripReady: stripFile !== "" && stripFor === sourcePath
            readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/dms-liquid-glass-bar"

            function refreshStrip() {
                if (!liveWanted)
                    return;
                if (stripFor !== sourcePath) {
                    stripFile = "";
                    stripKey = "";
                }
                if (videoInfo?.path !== sourcePath && !videoProbe.running) {
                    videoProbe.path = sourcePath;
                    videoProbe.running = true;
                }
            }

            Process {
                id: videoProbe
                property string path: ""
                command: ["sh", "-c", 'command -v ffprobe >/dev/null || exit 127; stat -c %Y -- "$1" && ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,avg_frame_rate:format=duration -of csv=p=0 -- "$1"', "sh", path]
                stdout: StdioCollector {
                    id: videoProbeOut
                }
                onExited: code => {
                    const lines = videoProbeOut.text.trim().split("\n");
                    const st = (lines[1] ?? "").split(",");
                    // The average frame rate: r_frame_rate can be a timebase like 1000/1.
                    const rate = s => {
                        const r = (s ?? "").split("/");
                        const v = Number(r[0]) / Number(r[1] || 1);
                        return v > 0 && v <= 240 ? v : 0;
                    };
                    const info = {
                        "path": path,
                        "mtime": lines[0],
                        "w": Number(st[0]),
                        "h": Number(st[1]),
                        "fps": rate(st[3]) || rate(st[2]),
                        "ms": Math.round(Number(lines[2]) * 1000)
                    };
                    if (path !== win.sourcePath)
                        Qt.callLater(win.refreshStrip); // the wallpaper changed while probing
                    else if (code !== 0 || !(info.w > 0 && info.h > 0))
                        console.info("liquidGlassBar: can't read the video wallpaper (is ffmpeg installed?); the glass keeps the still frame");
                    else
                        win.videoInfo = info;
                }
            }

            // The strip to cut: the frost/lens sampling area around the window, in video pixels,
            // laid out like DMS's video (crop, fit or stretch), snapped to 16 pixels so small
            // geometry changes don't need a new clip.
            readonly property var stripSpec: {
                const v = videoInfo;
                if (!liveWanted || !v || v.path !== sourcePath || screenW <= 0 || screenH <= 0)
                    return null;
                const a = blurArea;
                const mode = SessionData.getMonitorWallpaperFillMode(screen?.name ?? "");
                let kx = screenW / v.w, ky = screenH / v.h; // output px per video px
                if (mode === "Fit" || mode === "PreserveAspectFit")
                    kx = ky = Math.min(kx, ky);
                else if (mode !== "Stretch")
                    kx = ky = Math.max(kx, ky);
                const ox = (screenW - v.w * kx) / 2, oy = (screenH - v.h * ky) / 2;
                const q = 16;
                const x0 = Math.max(0, Math.floor((a.x - ox) / kx / q) * q), y0 = Math.max(0, Math.floor((a.y - oy) / ky / q) * q);
                const x1 = Math.min(v.w, Math.ceil((a.x + a.width - ox) / kx / q) * q), y1 = Math.min(v.h, Math.ceil((a.y + a.height - oy) / ky / q) * q);
                const cw = Math.floor((x1 - x0) / 2) * 2, chh = Math.floor((y1 - y0) / 2) * 2;
                if (cw < 16 || chh < 16)
                    return null;
                const scale = Math.min(1, kx * pxRatio, ky * pxRatio);
                const ow = Math.max(16, Math.round(cw * scale / 2) * 2), oh = Math.max(16, Math.round(chh * scale / 2) * 2);
                const fps = v.fps > 0 ? Math.min(root.liveFps, v.fps) : root.liveFps;
                const crop = "crop=" + cw + ":" + chh + ":" + x0 + ":" + y0;
                const clip = "scale=" + ow + ":" + oh + (v.fps > fps || !(v.fps > 0) ? ",fps=" + fps : "");
                // A tiny greyscale fingerprint of every video frame (at most 30 a second) in the gap
                // between the bar and the screen edge, to find which frame DMS shows. Along the bar
                // the gap is snapped to 16 video pixels too, so the clip key stays put.
                const band = gapBand();
                let sig = null;
                if (band && v.fps > 0) {
                    const along = !barVertical;
                    let bx0 = Math.max(0, Math.ceil((band.x - ox) / kx) - x0), by0 = Math.max(0, Math.ceil((band.y - oy) / ky) - y0);
                    let bx1 = Math.min(cw, Math.floor((band.x + band.width - ox) / kx) - x0), by1 = Math.min(chh, Math.floor((band.y + band.height - oy) / ky) - y0);
                    if (along) {
                        bx0 = Math.ceil(bx0 / q) * q;
                        bx1 = Math.floor(bx1 / q) * q;
                    } else {
                        by0 = Math.ceil(by0 / q) * q;
                        by1 = Math.floor(by1 / q) * q;
                    }
                    if ((along ? bx1 - bx0 : by1 - by0) >= 96 && (along ? by1 - by0 : bx1 - bx0) >= 2) {
                        const sw = along ? 96 : 2, sh = along ? 2 : 96;
                        const sigFps = Math.min(v.fps, 30);
                        sig = {
                            "filter": (v.fps > sigFps ? "fps=" + sigFps + "," : "") + "format=gray,crop=" + (bx1 - bx0) + ":" + (by1 - by0) + ":" + bx0 + ":" + by0 + ",scale=" + sw + ":" + sh + ":flags=area",
                            "w": sw,
                            "h": sh,
                            "fps": sigFps,
                            // A fingerprint shows the video frame nearest its own start time.
                            "phase": 0.5 * sigFps / v.fps,
                            "rect": Qt.rect(ox + (x0 + bx0) * kx, oy + (y0 + by0) * ky, (bx1 - bx0) * kx, (by1 - by0) * ky)
                        };
                    }
                }
                const filter = sig ? "[0:v]" + crop + ",split[a][b];[a]" + clip + "[clip];[b]" + sig.filter + "[sig]" : "[0:v]" + crop + "," + clip + "[clip]";
                return {
                    "key": Qt.md5(JSON.stringify([v.path, v.mtime, filter, 5])),
                    "filter": filter,
                    "fps": fps,
                    "rect": Qt.rect(ox + x0 * kx, oy + y0 * ky, cw * kx, chh * ky),
                    "sig": sig
                };
            }
            onStripSpecChanged: stripDebounce.restart()
            Timer {
                id: stripDebounce
                interval: 1500
                onTriggered: win.cutStrip()
            }

            function cutStrip() {
                const spec = stripSpec;
                if (!spec || spec.key === stripKey)
                    return;
                if (stripCutter.running) {
                    stripCutter.pending = true; // cut again once this one is done
                    return;
                }
                stripCutter.spec = spec;
                stripCutter.forPath = sourcePath;
                stripCutter.keep = Object.values(root.clipsInUse).filter(f => f);
                stripCutter.aborted = false;
                stripCutter.running = true;
            }

            Process {
                id: stripCutter
                property var spec: null
                property string forPath: ""
                property bool pending: false
                // Stopped on purpose (the wallpaper changed): not a failure.
                property bool aborted: false
                // Clips the glass windows are using, never pruned.
                property var keep: []
                readonly property string out: spec ? win.cacheDir + "/" + spec.key : ""
                // One JPEG per frame, so any frame can be shown directly and decodes in well under
                // a millisecond. Reuses a clip already cut, keeps the cache under about 200 MB
                // (least recently used clips go first, never one in use), and prints the number
                // of frames. ffmpeg stops with this script, even if it is killed outright.
                readonly property string script: [
                    'out=$1 src=$2 fc=$3 n=$4 dir=${1%/*}',
                    'shift 4',
                    'mkdir -p "$dir" || exit 1',
                    'find "$dir" -maxdepth 1 -name "*.part" -mmin +10 -exec rm -rf {} + 2>/dev/null',
                    'if [ ! -d "$out" ]; then',
                    '    command -v ffmpeg >/dev/null || exit 127',
                    '    tmp="$out.$$.part"',
                    '    trap \'rm -rf "$tmp"\' EXIT',
                    '    trap \'exit 1\' TERM INT HUP',
                    '    mkdir "$tmp" || exit 1',
                    '    if [ -n "$n" ]; then',
                    '        nice -n 10 ffmpeg -nostdin -v error -y -i "$src" -filter_complex "$fc" -map "[clip]" -an -sn -dn -q:v 3 "$tmp/%04d.jpg" -map "[sig]" -f rawvideo "$tmp/sig.raw" &',
                    '    else',
                    '        nice -n 10 ffmpeg -nostdin -v error -y -i "$src" -filter_complex "$fc" -map "[clip]" -an -sn -dn -q:v 3 "$tmp/%04d.jpg" &',
                    '    fi',
                    '    pid=$!',
                    '    trap \'kill $pid 2>/dev/null; wait $pid; exit 1\' TERM INT HUP',
                    '    (while kill -0 $pid 2>/dev/null; do kill -0 $$ 2>/dev/null || { kill $pid; sleep 1; rm -rf "$tmp"; break; }; sleep 1; done) >/dev/null 2>&1 &',
                    '    wait $pid || exit 1',
                    '    if [ -n "$n" ]; then',
                    '        od -An -v -tu1 -w"$n" "$tmp/sig.raw" > "$tmp/sig.txt" && rm -f "$tmp/sig.raw" || exit 1',
                    '    fi',
                    '    mv -T "$tmp" "$out" 2>/dev/null || rm -rf "$tmp"',
                    'fi',
                    '[ -d "$out" ] || exit 1',
                    'touch -c "$out" "$@"',
                    'total=0',
                    'ls -1td "$dir"/*/ | grep -v "\\.part/$" | while IFS= read -r f; do',
                    '    f=${f%/}',
                    '    total=$((total + $(du -sk -- "$f" | cut -f1)))',
                    '    [ "$total" -gt 204800 ] || continue',
                    '    keep=',
                    '    for k in "$out" "$@"; do [ "$f" = "$k" ] && keep=1; done',
                    '    [ -n "$keep" ] || rm -rf -- "$f"',
                    'done',
                    'ls "$out" | grep -c "\\.jpg$"'
                ].join("\n")
                command: ["sh", "-c", script, "sh", out, forPath, spec?.filter ?? "", spec?.sig ? String(spec.sig.w * spec.sig.h) : ""].concat(keep)
                stdout: StdioCollector {
                    id: stripCutterOut
                }
                onExited: code => {
                    const count = parseInt(stripCutterOut.text);
                    if (aborted) {
                        aborted = false;
                    } else if (code === 0 && count > 0 && forPath === win.sourcePath) {
                        win.stripFile = out;
                        win.stripFrames = count;
                        win.stripSig = spec.sig;
                        win.stripFps = spec.fps;
                        win.stripFor = forPath;
                        win.stripRect = spec.rect;
                        win.stripKey = spec.key;
                    } else if (forPath !== win.sourcePath) {
                        Qt.callLater(win.refreshStrip); // the wallpaper changed while cutting
                    } else {
                        console.info("liquidGlassBar: couldn't prepare the live video glass (is ffmpeg installed?); the glass keeps the still frame");
                        win.stripKey = spec.key; // don't retry this one until something changes
                    }
                    if (pending) {
                        pending = false;
                        Qt.callLater(win.cutStrip);
                    }
                }
            }
            onStripFileChanged: root.clipsInUse[modelData] = stripFile

            // The player only exists while it plays, and for a short while after DMS pauses or the
            // bar hides, so a quick overview or unlock doesn't reload it.
            readonly property bool livePlaying: dmsVideoPlays && shown
            onLivePlayingChanged: {
                if (livePlaying)
                    liveGrace.stop();
                else
                    liveGrace.restart();
            }
            Timer {
                id: liveGrace
                interval: 20000
            }

            // ---- measuring the clock against the screen ----------------------------------------

            // The wallpaper in the gap between the resting glass and the screen edge, away from the
            // glass's rounded ends (output coordinates), or null when there's no usable gap.
            function gapBand() {
                const b = lastShown;
                if (!b)
                    return null;
                const m = 2; // clear of the glass edge and the screen edge
                let r = null;
                if (!barVertical) {
                    const x = b.x + b.h, w = b.w - 2 * b.h;
                    if (anchors.bottom && !anchors.top)
                        r = Qt.rect(x, b.y + b.h + m, w, screenH - 1 - (b.y + b.h + m));
                    else if (anchors.top && !anchors.bottom)
                        r = Qt.rect(x, 1, w, b.y - m - 1);
                } else {
                    const y = b.y + b.w, h = b.h - 2 * b.w;
                    if (anchors.right && !anchors.left)
                        r = Qt.rect(b.x + b.w + m, y, screenW - 1 - (b.x + b.w + m), h);
                    else if (anchors.left && !anchors.right)
                        r = Qt.rect(1, y, b.x - m - 1, h);
                }
                return r && r.width >= 3 && r.height >= 3 ? r : null;
            }

            // The shell-start guess for the clock can be off by a tenth of a second or more. So
            // shortly after the glass starts moving (at most twice per clock, and once more after
            // DMS resumes the video, see updateClock), ClockCheck.qml matches a few screenshots of
            // the gap between the glass and the screen edge against fingerprints of the video, to
            // see which frame DMS really shows, and the clock is corrected.
            readonly property bool clockUnchecked: {
                const _dep = root.pluginService?.globalVars;
                const c = currentClock();
                return c !== null && c.since !== null && (c.checks ?? 0) < 2;
            }
            readonly property bool canCheck: livePlaying && stripReady && stripSig !== null
            readonly property bool wantCheck: canCheck && clockUnchecked

            function setClock(c) {
                root.pluginService.setGlobalVar(root.pluginId, clockKey(), c);
            }

            // Starts a check of this output's clock, if it has one to spare and no other bar on
            // this output is checking it. Counted before it runs, so it can never repeat endlessly.
            // Returns what endClockCheck and correctClock need, or null.
            function beginClockCheck() {
                const c = currentClock();
                const name = screen?.name ?? "";
                const owner = root.checkOwners[name];
                const now = Date.now();
                if (!c || c.since === null || c.since > now || (c.checks ?? 0) >= 2)
                    return null;
                if (owner && owner.key !== modelData && now - owner.at < 15000)
                    return null;
                root.checkOwners[name] = {
                    "key": modelData,
                    "at": now
                };
                c.checks = (c.checks ?? 0) + 1;
                c.lastCheck = now;
                setClock(c);
                return {
                    "screen": name,
                    "src": c.src,
                    "start": c.start
                };
            }

            function endClockCheck(t) {
                if (root.checkOwners[t.screen]?.key === modelData)
                    delete root.checkOwners[t.screen];
            }

            // Where the clock was at time `t` (ms since the epoch), or null.
            function clockPositionAt(t) {
                const c = currentClock();
                const d = videoInfo?.ms ?? 0;
                if (!c || c.since === null || d <= 0)
                    return null;
                return (c.base + Math.max(0, t - c.since)) % d;
            }

            // Moves the clock by `delta` ms, and marks it as checked, unless it's another clock by now.
            function correctClock(delta, t) {
                const c = currentClock();
                if (!c || c.since === null || c.src !== t.src || c.start !== t.start || screen?.name !== t.screen)
                    return;
                c.since -= delta;
                c.checks = 2;
                setClock(c);
            }

            Item {
                id: wallRoot
                x: -win.winX
                y: -win.winY
                width: win.screenW
                height: win.screenH

                Rectangle {
                    anchors.fill: parent
                    color: win.wallpaperIsColor ? win.wallpaper : SettingsData.effectiveWallpaperBackgroundColor
                }

                Image {
                    id: wallImg
                    anchors.fill: parent
                    source: win.wallpaperUrl
                    asynchronous: true
                    retainWhileLoading: true
                    smooth: true
                    mipmap: true
                    cache: true
                    sourceSize: Qt.size(Math.min(Math.round(win.screenW * win.pxRatio), 8192), Math.min(Math.round(win.screenH * win.pxRatio), 8192))
                    fillMode: Theme.getFillMode(SessionData.getMonitorWallpaperFillMode(win.screen?.name ?? ""))
                    onFillModeChanged: win.requestProbe()
                }

                // The clip of the strip behind the bar, over the still frame.
                Loader {
                    id: liveVideo
                    x: win.stripRect.x
                    y: win.stripRect.y
                    width: win.stripRect.width
                    height: win.stripRect.height
                    active: win.liveWanted && win.stripReady && (win.livePlaying || liveGrace.running)
                    // Qt caches components by URL for the life of the shell; bump ?v= after editing the file.
                    source: Qt.resolvedUrl("LiveVideoLayer.qml") + "?v=15"
                    onLoaded: item.clock = win

                    Binding {
                        target: liveVideo.item
                        when: liveVideo.item !== null
                        property: "folder"
                        value: win.stripFile
                    }
                    Binding {
                        target: liveVideo.item
                        when: liveVideo.item !== null
                        property: "frameCount"
                        value: win.stripFrames
                    }
                    Binding {
                        target: liveVideo.item
                        when: liveVideo.item !== null
                        property: "play"
                        value: win.livePlaying
                    }
                    Binding {
                        target: liveVideo.item
                        when: liveVideo.item !== null
                        property: "fps"
                        value: win.stripFps
                    }
                }
            }

            // Lives as long as the live video layer; does nothing between checks.
            Loader {
                id: clockCheck
                active: liveVideo.item !== null && win.stripSig !== null
                source: Qt.resolvedUrl("ClockCheck.qml") + "?v=7"
                onLoaded: item.clock = win

                Binding {
                    target: clockCheck.item
                    when: clockCheck.item !== null
                    property: "folder"
                    value: win.stripFile
                }
                Binding {
                    target: clockCheck.item
                    when: clockCheck.item !== null
                    property: "sig"
                    value: win.stripSig
                }
                Binding {
                    target: clockCheck.item
                    when: clockCheck.item !== null
                    property: "canRun"
                    value: win.canCheck
                }
                Binding {
                    target: clockCheck.item
                    when: clockCheck.item !== null
                    property: "checkWanted"
                    value: win.wantCheck
                }
            }

            // Output-clamped area around the window, in logical output coordinates.
            function areaAround(margin) {
                const x0 = Math.max(0, winX - margin), y0 = Math.max(0, winY - margin);
                const x1 = Math.min(screenW, winX + width + margin), y1 = Math.min(screenH, winY + height + margin);
                return Qt.rect(x0, y0, Math.max(1, x1 - x0), Math.max(1, y1 - y0));
            }

            // Wallpaper under and just around the window, one texel per device pixel.
            readonly property rect sharpArea: areaAround(24)
            // Wider, downscaled copy for the frost blur.
            readonly property rect blurArea: areaAround(40)

            ShaderEffectSource {
                id: sharpSrc
                sourceItem: wallRoot
                hideSource: true
                live: true
                smooth: true
                sourceRect: win.sharpArea
                textureSize: Qt.size(Math.max(1, Math.round(win.sharpArea.width * win.pxRatio)), Math.max(1, Math.round(win.sharpArea.height * win.pxRatio)))
                visible: false
            }

            ShaderEffectSource {
                id: blurSrc
                sourceItem: wallRoot
                hideSource: true
                live: true
                smooth: true
                sourceRect: win.blurArea
                textureSize: Qt.size(Math.max(1, Math.round(win.blurArea.width / 3)), Math.max(1, Math.round(win.blurArea.height / 3)))
                visible: false
            }

            ShaderEffect {
                anchors.fill: parent
                visible: win.drawGeo.valid && win.appear > 0
                blending: true

                property var sharpTex: sharpSrc
                property var blurTex: blurSrc
                property vector2d winSize: Qt.vector2d(win.width, win.height)
                property vector4d body: win.drawGeo.body ?? Qt.vector4d(0, 0, 0, 0)
                property vector4d radii: win.drawGeo.radii ?? Qt.vector4d(0, 0, 0, 0)
                property vector4d wingA: win.drawGeo.wingA?.rect ?? Qt.vector4d(0, 0, 0, 0)
                property vector4d wingAC: win.drawGeo.wingA?.disc ?? Qt.vector4d(0, 0, 1, 1)
                property vector4d wingB: win.drawGeo.wingB?.rect ?? Qt.vector4d(0, 0, 0, 0)
                property vector4d wingBC: win.drawGeo.wingB?.disc ?? Qt.vector4d(0, 0, 1, 1)
                property vector4d sharpRect: Qt.vector4d(win.sharpArea.x - win.winX, win.sharpArea.y - win.winY, win.sharpArea.width, win.sharpArea.height)
                property vector4d blurRect: Qt.vector4d(win.blurArea.x - win.winX, win.blurArea.y - win.winY, win.blurArea.width, win.blurArea.height)
                property vector4d tint: Qt.vector4d(root.tintColor.r, root.tintColor.g, root.tintColor.b, root.tintStrength)
                property real pxRatio: win.pxRatio
                readonly property real thickness: win.drawGeo.thickness ?? 0
                // A narrow rim: under a third of the bar's thickness.
                property real bevel: Math.max(3, Math.min(14, thickness * 0.28))
                property real depth: root.refraction * bevel * 0.8
                property real lensSign: root.lensMode === "wrap" ? -1 : 1
                property real frost: Math.min(1, root.frost * 1.5)
                property real blurRadius: 3 + 12 * root.frost
                property real saturation: root.saturation
                property real dispersion: root.dispersion * 0.4
                property real highlight: root.rimHighlight
                property real lift: 0.03
                property real fgLight: win.fgLight ? 1 : 0
                property real scrim: root.scrim
                property real shadow: root.shadow
                property vector4d contentTint: Qt.vector4d(win.avgColor.r, win.avgColor.g, win.avgColor.b, win.avgColor.a > 0 ? root.contentTint * 0.25 : 0)
                property vector2d hoverPos: Qt.vector2d(win.hoverPos.x, win.hoverPos.y)
                property real hover: root.hoverGlow ? win.hoverAmount : 0
                property real appear: win.appear

                // Qt caches shaders by URL for the life of the shell; bump ?v= after recompiling the .qsb.
                fragmentShader: Qt.resolvedUrl("shaders/liquid_glass.frag.qsb") + "?v=13"
            }
        }
    }

    // `dms ipc call liquidGlass set frost 40`, `dms ipc call liquidGlass get`
    IpcHandler {
        target: "liquidGlass"

        function set(key: string, value: string): string {
            if (!root.pluginService)
                return "ERROR: no plugin service";
            const n = Number(value);
            const v = value === "true" ? true : value === "false" ? false : value !== "" && !isNaN(n) ? n : value;
            root.pluginService.savePluginData(root.pluginId, key, v);
            return "OK";
        }

        function get(): string {
            return JSON.stringify(root.pluginData);
        }
    }

    Component.onDestruction: console.info("liquidGlassBar: stopped")
}
