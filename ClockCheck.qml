import QtQuick
import Quickshell
import Quickshell.Io

// Checks the live video glass clock against the screen. The guess the clock starts from can be
// off by a tenth of a second or more, because a plugin can't see when DMS's own player starts.
//
// The screenshots are taken by `grim`, in its own process. Quickshell's ScreencopyView can't be
// used here: on niri every screen copy binds the output a second time, niri then reports each of
// the shell's windows as entering that binding, and Qt takes it for a screen of its own. That
// left dangling screens in every window of the shell and crashed it now and then.
Item {
    id: check
    visible: false

    // The glass window: beginClockCheck(), endClockCheck(), clockPositionAt(t), correctClock(),
    // screen, modelData.
    property var clock: null
    // Folder of the current clip, which holds the fingerprints.
    property string folder: ""

    // The clip folder has a tiny greyscale fingerprint of the video (sig.txt: one line per frame,
    // at up to 30 frames a second) for the wallpaper in the gap between the glass and the screen
    // edge. A few screenshots of that gap, matched against the fingerprints, tell which frame DMS
    // really shows, and so how far off the clock is.
    // {w, h, fps, phase, rect}: fingerprint size, frame rate, where in its frame a fingerprint
    // was taken (in frames), and the gap on the output.
    property var sig: null
    // Whether the glass is playing this clip right now; a running check stops when it isn't.
    property bool canRun: false
    // Whether the clock wants a check (it has one to spare); never stops a running check.
    property bool checkWanted: false

    onCheckWantedChanged: {
        if (checkWanted)
            checkDelay.start(2500);
        else
            checkDelay.stop();
    }
    onCanRunChanged: {
        if (!canRun)
            stopCheck(0);
    }
    // A new clip: measure against its fingerprints instead.
    onFolderChanged: stopCheck(2500)
    onSigChanged: stopCheck(2500)
    Component.onDestruction: stopCheck(0)

    Timer {
        id: checkDelay
        function start(ms) {
            interval = ms;
            restart();
        }
        onTriggered: check.startCheck()
    }

    // The check in progress: {src, start, screen} of the clock it measures, and the fingerprint spec.
    property var token: null
    property var checkSig: null

    function startCheck() {
        if (!checkWanted || !canRun || !sig || token || !clock)
            return;
        if (shooter.running) {
            checkDelay.start(1000); // the last one is still being stopped
            return;
        }
        const t = clock.beginClockCheck();
        if (!t) {
            // Another bar on this output is checking, or the clock hasn't started yet.
            checkDelay.start(3000);
            return;
        }
        const scr = clock.screen;
        const pos = clock.clockPositionAt(Date.now());
        if (!scr || pos === null) {
            clock.endClockCheck(t);
            return;
        }
        token = t;
        checkSig = sig;
        const r = sig.rect;
        // Only the fingerprints around where the clock says the video is (3s either side of the
        // two seconds of screenshots) are read back, so long videos cost no more than short ones.
        const first = Math.floor((pos - 3000) * sig.fps / 1000);
        const count = Math.ceil(8000 * sig.fps / 1000);
        const dir = (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/dms-liquid-glass-bar-check-" + Qt.md5(String(clock.modelData)).slice(0, 12);
        shooter.command = ["bash", "-c", shooter.script, "bash", dir,
            Math.round(scr.x + r.x) + "," + Math.round(scr.y + r.y) + " " + Math.max(1, Math.round(r.width)) + "x" + Math.max(1, Math.round(r.height)),
            folder + "/sig.txt", String(first), String(count), String(sig.w), String(sig.h)];
        shooter.aborted = false;
        shooter.running = true;
        watchdog.restart();
    }

    // Stops the check in progress, if any, and tries again after `retryMs` if still wanted.
    function stopCheck(retryMs) {
        if (!token)
            return;
        watchdog.stop();
        if (shooter.running) {
            shooter.aborted = true;
            shooter.running = false;
        }
        release();
        if (retryMs > 0 && checkWanted)
            checkDelay.start(retryMs);
    }

    function release() {
        if (token && clock) {
            try {
                clock.endClockCheck(token);
            } catch (e) {}
        }
        token = null;
        checkSig = null;
    }

    // Never let a check hang around.
    Timer {
        id: watchdog
        interval: 12000
        onTriggered: check.stopCheck(15000)
    }

    // Eight screenshots of the gap, 200ms apart, then the fingerprints near the clock's position
    // and the screenshots shrunk to fingerprint size by ffmpeg (as the fingerprints were made).
    // Prints "T start end" (µs since the epoch) per screenshot, "N frames", "R index values..."
    // per fingerprint and "F values..." per screenshot.
    Process {
        id: shooter
        property bool aborted: false
        readonly property string script: [
            't=$1 n=$(($6 * $7))',
            'command -v grim >/dev/null && command -v ffmpeg >/dev/null || exit 127',
            'rm -rf "$t"; mkdir -p "$t" || exit 1',
            'trap \'rm -rf "$t"\' EXIT',
            'trap \'exit 1\' TERM INT HUP',
            'k=0',
            'for i in 1 2 3 4 5 6 7 8; do',
            '    [ $i -gt 1 ] && sleep 0.2',
            '    t0=$EPOCHREALTIME',
            '    timeout 1 grim -g "$2" -s 1 -t ppm "$t/$((k + 1)).ppm" 2>/dev/null || continue',
            '    t1=$EPOCHREALTIME',
            '    k=$((k + 1))',
            '    echo "T ${t0/,/.} ${t1/,/.}"',
            'done',
            '[ $k -gt 0 ] || exit 1',
            'rows=$(wc -l < "$3") && [ "$rows" -gt 0 ] || exit 1',
            'echo "N $rows"',
            'awk -v a="$4" -v c="$5" -v n="$rows" \'{ i = NR - 1; d = ((i - a) % n + n) % n; if (n <= c || d < c) print "R", i, $0 }\' "$3"',
            'timeout 5 ffmpeg -nostdin -v error -i "$t/%d.ppm" -vf "format=gray,scale=$6:$7:flags=area" -f rawvideo - | od -An -v -tu1 -w"$n" | sed "s/^/F/"'
        ].join("\n")
        stdout: StdioCollector {
            id: shooterOut
        }
        onExited: code => {
            watchdog.stop();
            if (aborted) {
                aborted = false;
                return;
            }
            const results = code === 0 && check.checkSig ? check.measure(shooterOut.text, check.checkSig) : [];
            check.finishCheck(results);
        }
    }

    // Zero mean, unit length.
    function normalized(v) {
        let mean = 0;
        for (const x of v)
            mean += x;
        mean /= v.length;
        let len = 0;
        const out = new Float32Array(v.length);
        for (let i = 0; i < v.length; i++) {
            out[i] = v[i] - mean;
            len += out[i] * out[i];
        }
        len = Math.sqrt(len) || 1;
        for (let i = 0; i < v.length; i++)
            out[i] /= len;
        return out;
    }

    // A screenshot's moving part: each line along the band is fitted to what every fingerprint
    // shares (gain and offset absorb the glass's shadow and colour handling), and what's left is
    // compared.
    function shotResidual(shot, sg, mean) {
        const wide = sg.w >= sg.h;
        const lines = wide ? sg.h : sg.w, along = wide ? sg.w : sg.h;
        const out = new Array(shot.length).fill(0);
        for (let l = 0; l < lines; l++) {
            const idx = k => wide ? l * sg.w + k : k * sg.w + l;
            let mx = 0, my = 0;
            for (let k = 0; k < along; k++) {
                mx += mean[idx(k)] / along;
                my += shot[idx(k)] / along;
            }
            let sxy = 0, sxx = 0;
            for (let k = 0; k < along; k++) {
                sxy += (mean[idx(k)] - mx) * (shot[idx(k)] - my);
                sxx += (mean[idx(k)] - mx) * (mean[idx(k)] - mx);
            }
            const a = sxx > 0 ? sxy / sxx : 0;
            for (let k = 0; k < along; k++)
                out[idx(k)] = shot[idx(k)] - my - a * (mean[idx(k)] - mx);
        }
        return normalized(out);
    }

    // How far off the clock is (ms) for each screenshot that clearly matches a fingerprint.
    function measure(text, sg) {
        const len = sg.w * sg.h;
        const times = [], shots = [], rows = new Map();
        let total = 0;
        for (const line of text.split("\n")) {
            const v = line.slice(1).trim().split(/\s+/).map(Number);
            switch (line[0]) {
            case "T":
                // The copy is made just before grim gets it back, and is then about as old as the
                // frame the glass would show: take the end of each run, a little earlier.
                times.push(v[1] * 1000 - 5);
                break;
            case "N":
                total = v[0];
                break;
            case "R":
                if (v.length === len + 1)
                    rows.set(v[0], v.slice(1));
                break;
            case "F":
                if (v.length === len)
                    shots.push(v);
                break;
            }
        }
        if (rows.size === 0 || total <= 0 || shots.length !== times.length)
            return [];
        // The fingerprints minus what they all share (the still parts of the picture).
        const mean = new Float32Array(len);
        for (const f of rows.values())
            for (let i = 0; i < len; i++)
                mean[i] += f[i] / rows.size;
        const frames = new Map();
        for (const [i, f] of rows)
            frames.set(i, normalized(f.map((x, j) => x - mean[j])));
        const d = total * 1000 / sg.fps;
        const out = [];
        for (let s = 0; s < shots.length; s++) {
            const shot = shotResidual(shots[s], sg, mean);
            const scores = new Map();
            let best = -2, bi = -1;
            for (const [i, fr] of frames) {
                let dot = 0;
                for (let j = 0; j < len; j++)
                    dot += shot[j] * fr[j];
                scores.set(i, dot);
                if (dot > best) {
                    best = dot;
                    bi = i;
                }
            }
            const clockPos = clock.clockPositionAt(times[s]);
            if (bi < 0 || best < 0.9 || clockPos === null)
                continue;
            // Refined between its neighbours, when both were read.
            const a = scores.get((bi - 1 + total) % total), c = scores.get((bi + 1) % total);
            const den = a !== undefined && c !== undefined ? a - 2 * best + c : 0;
            const sub = den < 0 ? Math.max(-0.5, Math.min(0.5, 0.5 * (a - c) / den)) : 0;
            const shown = (bi + sg.phase + sub) * 1000 / sg.fps;
            out.push(((shown - clockPos) % d + 1.5 * d) % d - d / 2);
        }
        return out;
    }

    function finishCheck(deltas) {
        const t = token;
        release();
        // At least three screenshots must agree on the offset, within about two video frames
        // (some may match the wrong frame where the picture hardly moves).
        let agree = [];
        for (const x of deltas) {
            const near = deltas.filter(y => Math.abs(y - x) <= 40);
            if (near.length > agree.length)
                agree = near;
        }
        if (t && agree.length >= 3)
            clock.correctClock(agree.reduce((x, y) => x + y, 0) / agree.length, t);
        else if (checkWanted)
            checkDelay.start(15000); // no clear match: keep the clock, and try once more later
    }
}
