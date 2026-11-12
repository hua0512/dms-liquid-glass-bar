import QtQuick

// The moving picture behind the bar for live video glass: the frames of a small clip cut from the
// video wallpaper (one JPEG per frame), stretched over the area they were cut from. Nothing plays
// by itself: each frame is picked from the plugin's clock of where DMS's own player is, so the glass
// can't drift from that clock, and frames are decoded off the UI thread.
// Only exists while live video glass plays, and for a short while after it pauses.
Item {
    id: layer

    // Folder of the clip's frames (0001.jpg, ...), their number and frame rate.
    property string folder: ""
    property int frameCount: 0
    property real fps: 24
    // Advance only while DMS plays its video and the bar is on screen.
    property bool play: false
    // The glass window, whose position() says where DMS's player is now (ms, or null).
    property var clock: null

    property int frame: -1
    readonly property bool playing: play && frameCount > 0
    readonly property string folderUrl: folder ? "file://" + folder.split('/').map(s => encodeURIComponent(s)).join('/') + "/" : ""

    // Show the frame for the clock's position, and wake up when the next one is due.
    function showFrame() {
        const pos = clock ? clock.position() : null;
        if (pos === null || frameCount <= 0)
            return;
        const f = Math.round(pos * fps / 1000);
        frame = (f % frameCount + frameCount) % frameCount;
        tick.interval = Math.max(4, Math.ceil((f + 0.5) * 1000 / fps - pos));
    }

    onPlayChanged: showFrame()
    onClockChanged: showFrame()
    onFrameCountChanged: showFrame()

    Timer {
        id: tick
        repeat: true
        running: layer.playing
        onTriggered: layer.showFrame()
    }

    Image {
        anchors.fill: parent
        source: layer.frame >= 0 && layer.folderUrl ? layer.folderUrl + String(layer.frame + 1).padStart(4, "0") + ".jpg" : ""
        asynchronous: true
        cache: false
        // Keep showing the last frame until the next one is decoded.
        retainWhileLoading: true
        smooth: true
    }
}
