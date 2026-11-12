import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Services
import qs.Modules.Plugins

// Puts a Bottom-layer window under each DMS bar and renders the wallpaper behind the bar's
// shape through a liquid-glass shader. The bar sits on the Top layer, so its widgets stay on top.
// Everything is static: the window only repaints when wallpaper, bar geometry or settings change.
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
    // Re-colour the bar's widgets light or dark to suit what is behind the bar (like the macOS
    // menu bar), independent of the global light/dark mode.
    readonly property bool adaptiveForeground: pluginData?.adaptiveForeground ?? true
    readonly property string tintMode: pluginData?.tintMode ?? "auto"
    readonly property string lensMode: pluginData?.lensMode ?? "magnify"
    // "capsule" draws fully rounded ends inside the bar's body; "bar" follows the bar's own corners.
    readonly property string shapeMode: pluginData?.shape ?? "capsule"

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

    Variants {
        model: root.barWindows

        delegate: PanelWindow {
            id: win

            required property var modelData
            readonly property var bar: modelData

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

            function findSurface(item, depth) {
                if (!item || depth > 14)
                    return null;
                if (isBarSurface(item))
                    return item;
                const kids = item.children;
                for (let i = 0; i < kids.length; i++) {
                    const found = findSurface(kids[i], depth + 1);
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
                fgTarget = null;
                surf = null;
                surfBody = null;
            }

            function attach() {
                detach();
                const ci = bar?.contentItem;
                const s = findSurface(ci, 0);
                if (!s) {
                    geo = {
                        "valid": false
                    };
                    retryAttach.restart();
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
                    retryAttach.restart();
                    return;
                }
                surf = s;
                surfBody = b;
                fgTarget = findItem(ci, 0, isBarContent);
                setRemap(remapActive);

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

            function scheduleUpdate() {
                Qt.callLater(win.updateGeometry);
            }

            // ---- adaptive foreground ------------------------------------------------------

            // Which foreground reads better over the wallpaper behind the text band of the glass:
            // the 10th-percentile contrast of light and of dark text, measured on the CPU from a
            // tiny downsample whenever the wallpaper or the bar geometry changes. Using a low
            // percentile rather than the mean keeps light text off a bar with bright patches.
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
                Qt.callLater(() => lumaProbe.requestPaint());
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
                    fragmentShader: Qt.resolvedUrl("shaders/fg_remap.frag.qsb") + "?v=9"
                }
            }

            Timer {
                id: probeRetry
                property int attempts: 0
                interval: 150
                onTriggered: lumaProbe.requestPaint()
            }

            // A small copy of the wallpaper (native aspect) just for measuring.
            Image {
                id: probeImg
                width: 1
                height: 1
                opacity: 0
                source: win.wallpaperUrl
                asynchronous: true
                cache: false
                sourceSize.width: 384
                onStatusChanged: {
                    if (status === Image.Ready)
                        win.requestProbe();
                }
            }

            Canvas {
                id: lumaProbe
                // Whole wallpaper, drawn at the probe image's aspect.
                width: 384
                height: Math.max(1, Math.round(384 * (probeImg.implicitHeight || 216) / (probeImg.implicitWidth || 384)))
                opacity: 0
                renderStrategy: Canvas.Immediate
                renderTarget: Canvas.Image

                onPaint: {
                    const ctx = getContext("2d");
                    if (!ctx)
                        return;
                    // Relative luminance (linear) and WCAG contrast against light and dark text.
                    const lin = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
                    const lumY = (r, g, b) => 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
                    const lightY = 0.75, darkY = 0.012;
                    if (win.wallpaperIsColor) {
                        const c = Qt.color(win.wallpaper);
                        const y = lumY(c.r, c.g, c.b);
                        win.chooseForeground((lightY + 0.05) / (y + 0.05), (y + 0.05) / (darkY + 0.05));
                        return;
                    }
                    const g = win.geo;
                    if (probeImg.status !== Image.Ready || !g.valid)
                        return;
                    const cw = width, ch = height;
                    ctx.clearRect(0, 0, cw, ch);
                    // Qt's canvas scales item sources by the device pixel ratio; compensate, and fall
                    // back to the plain size if the image then doesn't cover the canvas.
                    ctx.drawImage(probeImg, 0, 0, cw / win.pxRatio, ch / win.pxRatio);
                    if (ctx.getImageData(Math.floor(cw * 0.9), Math.floor(ch * 0.9), 1, 1).data[3] === 0) {
                        ctx.clearRect(0, 0, cw, ch);
                        ctx.drawImage(probeImg, 0, 0, cw, ch);
                    }
                    // Where the output sits on the canvas, using the wallpaper's fill mode.
                    const W = win.screenW, H = win.screenH;
                    let kx = W / cw, ky = H / ch;
                    if (wallImg.fillMode === Image.PreserveAspectCrop)
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
                    const lightC = [], darkC = [];
                    for (let i = 0; i < data.length; i += 4) {
                        if (data[i + 3] === 0)
                            continue;
                        const y = lumY(data[i] / 255, data[i + 1] / 255, data[i + 2] / 255);
                        lightC.push((lightY + 0.05) / (y + 0.05));
                        darkC.push((y + 0.05) / (darkY + 0.05));
                    }
                    if (lightC.length > 0) {
                        probeRetry.attempts = 0;
                        const p10 = arr => arr.sort((a, b) => a - b)[Math.floor(arr.length * 0.1)];
                        win.chooseForeground(p10(lightC), p10(darkC));
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
                const p = w.mapToItem(ci, 0, 0);
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
                const ci = bar?.contentItem;
                const s = surf, b = surfBody;
                if (!ci || !s || !b) {
                    geo = {
                        "valid": false
                    };
                    return;
                }
                let shown = bar.visible && b.visible;
                for (let it = b; shown && it && it !== ci; it = it.parent) {
                    if (!it.visible || it.opacity <= 0)
                        shown = false;
                }
                const p = b.mapToItem(ci, 0, 0);
                const body = {
                    "x": p.x,
                    "y": p.y,
                    "w": b.width,
                    "h": b.height
                };
                const capsule = root.shapeMode === "capsule";
                const cap = Math.min(body.w, body.h) / 2;
                const onScreen = body.w > 0 && body.h > 0 && body.x < ci.width && body.y < ci.height && body.x + body.w > 0 && body.y + body.h > 0;
                geo = {
                    "valid": shown && onScreen,
                    "body": Qt.vector4d(body.x, body.y, body.w, body.h),
                    "radii": capsule ? Qt.vector4d(cap, cap, cap, cap) : Qt.vector4d(b.topLeftRadius, b.topRightRadius, b.bottomRightRadius, b.bottomLeftRadius),
                    "thickness": Math.min(body.w, body.h),
                    "wingA": capsule ? null : wingGeo(s.leadingWing, ci, body),
                    "wingB": capsule ? null : wingGeo(s.trailingWing, ci, body)
                };
                requestProbe();
            }

            Timer {
                id: retryAttach
                interval: 500
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
                    Qt.callLater(win.attach);
                }
            }

            Connections {
                target: root
                function onShapeChanged() {
                    win.scheduleUpdate();
                }
            }

            Component.onCompleted: attach()
            Component.onDestruction: detach()

            // ---- layer surface ------------------------------------------------------------

            screen: bar.screen
            color: "transparent"
            visible: geo.valid
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Bottom
            WlrLayershell.namespace: "dms:liquid-glass"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            mask: Region {}

            anchors.top: bar.anchors.top
            anchors.bottom: bar.anchors.bottom
            anchors.left: bar.anchors.left
            anchors.right: bar.anchors.right
            margins.top: bar.margins.top
            margins.bottom: bar.margins.bottom
            margins.left: bar.margins.left
            margins.right: bar.margins.right
            implicitWidth: bar.width
            implicitHeight: bar.height

            readonly property real screenW: screen?.width ?? 0
            readonly property real screenH: screen?.height ?? 0
            readonly property real pxRatio: CompositorService.getScreenScale(screen)
            // Where this window sits on the output, in logical pixels.
            readonly property real winX: anchors.left ? margins.left : anchors.right ? screenW - width - margins.right : Math.round((screenW - width) / 2)
            readonly property real winY: anchors.top ? margins.top : anchors.bottom ? screenH - height - margins.bottom : Math.round((screenH - height) / 2)

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
                visible: win.geo.valid
                blending: true

                property var sharpTex: sharpSrc
                property var blurTex: blurSrc
                property vector2d winSize: Qt.vector2d(win.width, win.height)
                property vector4d body: win.geo.body ?? Qt.vector4d(0, 0, 0, 0)
                property vector4d radii: win.geo.radii ?? Qt.vector4d(0, 0, 0, 0)
                property vector4d wingA: win.geo.wingA?.rect ?? Qt.vector4d(0, 0, 0, 0)
                property vector4d wingAC: win.geo.wingA?.disc ?? Qt.vector4d(0, 0, 1, 1)
                property vector4d wingB: win.geo.wingB?.rect ?? Qt.vector4d(0, 0, 0, 0)
                property vector4d wingBC: win.geo.wingB?.disc ?? Qt.vector4d(0, 0, 1, 1)
                property vector4d sharpRect: Qt.vector4d(win.sharpArea.x - win.winX, win.sharpArea.y - win.winY, win.sharpArea.width, win.sharpArea.height)
                property vector4d blurRect: Qt.vector4d(win.blurArea.x - win.winX, win.blurArea.y - win.winY, win.blurArea.width, win.blurArea.height)
                property vector4d tint: Qt.vector4d(root.tintColor.r, root.tintColor.g, root.tintColor.b, root.tintStrength)
                property real pxRatio: win.pxRatio
                readonly property real thickness: win.geo.thickness ?? 0
                // A narrow rim: about a fifth of the bar's thickness.
                property real bevel: Math.max(3, Math.min(12, thickness * 0.24))
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

                // Qt caches shaders by URL for the life of the shell; bump ?v= after recompiling the .qsb.
                fragmentShader: Qt.resolvedUrl("shaders/liquid_glass.frag.qsb") + "?v=10"
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
            root.pluginService.savePluginData(root.pluginId, key, value !== "" && !isNaN(n) ? n : value);
            return "OK";
        }

        function get(): string {
            return JSON.stringify(root.pluginData);
        }
    }

    Component.onCompleted: console.info("liquidGlassBar: started")
    Component.onDestruction: console.info("liquidGlassBar: stopped")
}
