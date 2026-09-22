import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root

    moduleName: "davedes.workspace-restorer"
    ipcTarget: "workspace-restorer"

    property var profiles: []
    property bool isSnapshotting: false
    property bool isRestoring: false
    property string lastAction: ""
    property string profileDir: Quickshell.env("HOME") + "/.config/omarchy/workspace-restorer"
    // Path to the hardened profile store helper. All profile-dir reads and
    // writes go through it (never a shell `ls`/`cat`/`rm` on user paths); it
    // no-follow-opens, fstats for regular/user-owned files, bounds sizes and
    // cardinality, and routes save payloads over stdin (no temp files).
    readonly property string storeScript: Qt.resolvedUrl("scripts/profile_store.py").toString().replace(/^file:\/\//, "")
    property var pendingSnapshot: null
    property bool showingNameInput: false
    property var monitorMap: ({})
    property var _monitorsCaptured: []

    readonly property color hoverBg: bar
        ? Style.hoverFillFor(bar.foreground, Color.accent)
        : Qt.darker(Color.bar.text, 1.1)
    readonly property color selectedBg: bar
        ? Style.selectedFillFor(bar.foreground, Color.accent)
        : Qt.darker(Color.bar.text, 1.15)

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    Component.onCompleted: {
        ensureProfileDir()
        buildMonitorMap()
    }

    // Guarantee the profile directory exists before any save/read. Uses the
    // store helper (not a shell mkdir) so the directory is created 0700 and
    // re-lstat-checked; the profile listing is chained onto its success so the
    // first load never races the directory creation.
    function ensureProfileDir() {
        initProc.command = ["python3", root.storeScript, "init", root.profileDir]
        initProc.running = true
    }

    Process {
        id: initProc
        onExited: function(exitCode) {
            if (exitCode === 0) root.refreshProfiles()
        }
    }

    function notify(summary, body) {
        Quickshell.execDetached(["notify-send", "-a", "Workspace Restorer", "-i", "preferences-desktop-workspaces", summary, body || ""])
    }

    // Return a valid, safe profile filename (without the .json suffix) or null.
    // Prevents path traversal: rejects separators, "..", leading dots (hidden
    // files), control characters, and overly long names so a crafted profile
    // name can never escape the profile directory on save/read/delete.
    function sanitizeProfileName(name) {
        if (typeof name !== "string") return null
        var n = name.trim()
        if (n.length === 0 || n.length > 128) return null
        if (n === "." || n === "..") return null
        if (n.charAt(0) === ".") return null
        if (/[\/\\\x00-\x1f]/.test(n)) return null
        if (!/^[A-Za-z0-9][A-Za-z0-9._ \-]*$/.test(n)) return null
        return n
    }

    // Add a nested-cardinality guard mirroring restoreLogic.mjs. A profile is
    // command-launch input, so window and tab counts are capped even when a
    // profile was hand-edited; the store helper enforces the same caps, this is
    // defense in depth on the consuming side. Returns the profile or null.
    function enforceProfileCardinality(profile) {
        if (!profile || typeof profile !== "object" || Array.isArray(profile)) return null
        if (!Array.isArray(profile.windows) || profile.windows.length > 512) return null
        for (var i = 0; i < profile.windows.length; i++) {
            var w = profile.windows[i]
            if (!w || typeof w !== "object" || Array.isArray(w)) return null
            if (Array.isArray(w.tabs) && w.tabs.length > 300) return null
        }
        if (typeof profile.comment === "string" && profile.comment.length > root.commentMaxLength) return null
        return profile
    }

    readonly property int commentMaxLength: 4000

    // Clean up a user-typed snapshot note before it's stored: normalizes line
    // endings, strips control characters (newlines/tabs excepted - it's meant
    // to stay multiline), and caps length. Mirrors MAX_COMMENT_LENGTH in
    // scripts/profile_store.py. Never null - worst case an empty string, so
    // callers can always safely call .length/.split on the result.
    function sanitizeComment(raw) {
        if (typeof raw !== "string") return ""
        var v = raw.replace(/\r\n/g, "\n").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "")
        if (v.length > root.commentMaxLength) v = v.slice(0, root.commentMaxLength)
        return v
    }

    // Shell-quote a string so a crafted value used in generated shell code
    // cannot break out into a new command. Use for ALL profile/window-derived
    // values injected into restore commands.
    function shellArg(s) {
        if (s === null || s === undefined) return "''"
        return "'" + String(s).replace(/'/g, "'\\''") + "'"
    }

    // Build a safe relaunch command line from an editable profile "command".
    // The executable token is restricted to a plain path/name (no shell
    // metacharacters) and every token is shell-quoted, so a crafted profile
    // cannot smuggle in $(...), backticks, ;, |, redirections, etc. Returns a
    // ready-to-execute command string, or "" if nothing usable.
    function sanitizeLaunchCommand(raw, fallbackClass) {
        var src = raw || (fallbackClass ? fallbackClass.toLowerCase() : "")
        var tokens = String(src).split(/\s+/).filter(function(t) { return t.length > 0 })
        if (tokens.length === 0) return ""
        // First token is the executable: must be a plain name or ./-relative path.
        if (!/^(\.?\/)?[A-Za-z0-9_][A-Za-z0-9_.+/-]*$/.test(tokens[0])) return ""
        var out = []
        for (var i = 0; i < tokens.length; i++) out.push(root.shellArg(tokens[i]))
        return out.join(" ")
    }

    // Validate a tab URL before it is injected into a launch command. Accepts
    // http/https and a conservative set of special schemes, and rejects anything
    // with shell metacharacters or whitespace so a crafted/compromised URL can
    // never break out of the generated bash. Mirrors restoreLogic.mjs safeUrl().
    function safeUrl(url) {
        if (typeof url !== "string") return null
        var u = url.trim()
        if (u.length === 0 || u.length > 4096) return null
        if (!/^[a-z][a-z0-9+.-]*:\/\/\S+$/i.test(u)) {
            if (/^(about|chrome|edge|brave|moz-extension|file|view-source|chrome-extension):/i.test(u)) {
                if (/[\s`$;|&<>"'\\\x00-\x1f]/.test(u)) return null
                return u
            }
            return null
        }
        if (/[\s`$;|&<>"'\\\x00-\x1f]/.test(u)) return null
        return u
    }

    // Build a shell-quoted list of validated, non-blank tab URLs from a window's
    // captured tabs array. Returns "" if there are no usable tabs.
    function buildTabUrls(tabs) {
        if (!Array.isArray(tabs)) return ""
        var out = []
        for (var i = 0; i < tabs.length; i++) {
            var tab = tabs[i]
            if (!tab || typeof tab.url !== "string") continue
            var url = root.safeUrl(tab.url)
            if (url === null) continue
            var lower = url.toLowerCase()
            if (lower === "about:newtab" || lower === "about:blank" || lower === "") continue
            out.push(root.shellArg(url))
        }
        return out.join(" ")
    }

    // Append tab URLs (with --new-window) to a browser's relaunch command so a
    // restored snapshot reopens a browser's pages. `pureCommand` is the already
    // shell-quoted launch command from the profile. Mirrors restoreLogic.mjs.
    function buildBrowserLaunchCommand(pureCommand, cls, tabs) {
        var cmd = pureCommand || ""
        var type = root.browserTypeForClass(cls)
        if (!type) return cmd
        var urls = root.buildTabUrls(tabs)
        if (urls.length === 0) return cmd
        var base = cmd.length > 0 ? cmd : root.shellArg(cls.toLowerCase())
        // Strip a stale `--new-window <urls>` tail left over from a previous
        // restore (the captured /proc cmdline still carries it), otherwise
        // we'd append another URL list and reopen duplicates.
        var marker = base.indexOf(" --new-window ")
        if (marker !== -1) base = base.slice(0, marker)
        return base + " --new-window " + urls
    }

    // Returns an array of shell commands to run in sequence (one per step) to
    // reopen a browser window's tabs. Mirrors restoreLogic.mjs. URLs are passed
    // without `--new-window` because both Firefox and Vivaldi when already
    // running forward that command as one-window-per-URL or add their own
    // session-restore tabs.  Open URLs as plain arguments so they become new
    // tabs in the existing window (one window, all tabs, no duplicates).
    function buildBrowserLaunchCommands(pureCommand, cls, tabs) {
        var cmd = pureCommand || ""
        var type = root.browserTypeForClass(cls)
        if (!type) return cmd.length > 0 ? [cmd] : []
        var urls = root.buildTabUrls(tabs)
        if (urls.length === 0) return cmd.length > 0 ? [cmd] : []
        var base = cmd.length > 0 ? cmd : root.shellArg(cls.toLowerCase())
        var marker = base.indexOf(" --new-window ")
        if (marker !== -1) base = base.slice(0, marker)
        return [base + " " + urls]
    }

    // Validate a workspace name from editable metadata. Real workspaces are
    // short strings of digits (optionally with a name/label), so only accept
    // a conservative safe set to keep it from injecting shell/jq. Also accept
    // Hyprland/Omarchy special workspaces (e.g. the scratchpad, reported by
    // hyprctl as "special:scratchpad"), which use a "special:" prefix ahead
    // of the same safe name charset.
    function safeWorkspace(ws) {
        if (typeof ws !== "string") return null
        if (!/^(special:)?[_a-z0-9]{1,32}$/i.test(ws)) return null
        return ws
    }

    // Validate a Hyprland window class used in jq/shell filters to prevent
    // injection through editable metadata.
    function safeClass(cls) {
        if (typeof cls !== "string") return null
        if (!/^[A-Za-z0-9_.-]{1,128}$/.test(cls)) return null
        return cls
    }

    // Coerce an editable coordinate/size value to a finite number so it can
    // never smuggle shell metacharacters into a generated dispatch.
    function numOr(v) {
        var n = Number(v)
        return isFinite(n) ? Math.round(n) : 0
    }

    // Pick a Nerd Font glyph that fits a profile name, falling back to a
    // generic icon when no keyword matches.
    function profileIconFor(name) {
        var n = (name || "").toLowerCase()
        if (/code|dev|coding|prog|program|project/.test(n)) return "\ue796"            // code
        if (/work|office|job/.test(n)) return "\uf0c0"                                  // briefcase/users
        if (/photo|image|picture|gimp|design|edit|art|draw/.test(n)) return "\uf1c5"    // image
        if (/music|audio|song|media/.test(n)) return "\ue602"                           // music
        if (/game|play|gaming/.test(n)) return "\uf11b"                                 // gamepad
        if (/web|internet|www|browser|search/.test(n)) return "\ue700"                  // globe
        if (/video|movie|film|stream/.test(n)) return "\uf03d"                          // film
        if (/term|shell|cli|console/.test(n)) return "\uf120"                           // terminal
        if (/chat|discord|telegram|message|slack/.test(n)) return "\uf086"              // comments
        if (/doc|note|write|text|paper/.test(n)) return "\uf15c"                        // file-text
        if (/file|folder|fm|nautilus|browse/.test(n)) return "\uf07b"                   // folder
        if (/mail|email|gmail/.test(n)) return "\uf0e0"                                 // envelope
        if (/home|default/.test(n)) return "\uf015"                                     // home
        return "\uf2db"                                                                 // fingerprint/workspaces default
    }

    function generateDefaultName() {
        var d = new Date()
        var pad = function(n) { return n < 10 ? "0" + n : "" + n }
        return "snapshot-" + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) +
               "-" + pad(d.getHours()) + pad(d.getMinutes())
    }

    function buildMonitorMap() {
        monitorMapProc.running = true
    }

    Process {
        id: monitorMapProc
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var monitors = JSON.parse(text)
                    var map = {}
                    for (var i = 0; i < monitors.length; i++) {
                        map[monitors[i].id] = monitors[i].name
                    }
                    root.monitorMap = map
                } catch(e) {}
            }
        }
    }

    // --- Window grouping (tabbed windows). Mirrors the pure helpers in
    // restoreLogic.mjs - kept in sync with the QML-side snapshot/restore. ---

    // Hyprland reports each grouped (tabbed) window's `grouped` field as the
    // full list of member addresses, in tab order, identically on every
    // member. From a raw `hyprctl -j clients` array, assign every member a
    // stable groupId (shared by all windows in that group, scoped to this
    // one snapshot) and a groupOrder (its index in the shared tab order).
    // Windows that aren't grouped, or are a lone leftover group of one, get
    // neither.
    function buildGroupMeta(clients) {
        var meta = {}
        if (!Array.isArray(clients)) return meta
        var groupIdByKey = {}
        var nextGroupId = 0
        for (var i = 0; i < clients.length; i++) {
            var c = clients[i]
            if (!c || typeof c.address !== "string") continue
            var grouped = Array.isArray(c.grouped) ? c.grouped : []
            if (grouped.length <= 1) continue
            var order = grouped.indexOf(c.address)
            if (order === -1) continue
            var key = grouped.slice().sort().join(",")
            if (!(key in groupIdByKey)) groupIdByKey[key] = nextGroupId++
            meta[c.address] = { groupId: groupIdByKey[key], groupOrder: order }
        }
        return meta
    }

    // From a profile's windows array (each optionally carrying .groupId /
    // .groupOrder, as attached by buildGroupMeta at snapshot time), collect
    // the groups that still have 2+ members. For each, pick the
    // lowest-groupOrder member as the fixed position reference (refIndex,
    // used only for merge-direction math - restore may end up resolving
    // members in a different order at runtime) and list every member's
    // window index in groupOrder.
    function buildRestoreGroups(windows) {
        if (!Array.isArray(windows)) return []
        var byId = {}
        for (var i = 0; i < windows.length; i++) {
            var w = windows[i]
            if (!w || w.groupId === null || w.groupId === undefined) continue
            var gid = w.groupId
            if (!byId[gid]) byId[gid] = []
            byId[gid].push({ index: i, order: (typeof w.groupOrder === "number" ? w.groupOrder : 0) })
        }
        var groups = []
        for (var gid2 in byId) {
            var members = byId[gid2]
            if (members.length < 2) continue
            members.sort(function (a, b) { return a.order - b.order })
            groups.push({
                groupId: gid2,
                refIndex: members[0].index,
                members: members.map(function (m) { return m.index })
            })
        }
        return groups
    }

    // Pick which of Hyprland's four `into_group` directions ('l'/'r'/'u'/'d')
    // should carry memberWin into a group with refWin, based on their
    // captured snapshot positions (grouped windows share one tile/rect, so
    // for most groups this is a degenerate 0,0 delta and any direction
    // works).
    function mergeDirectionFor(refWin, memberWin) {
        var rx = refWin && Array.isArray(refWin.position) ? root.numOr(refWin.position[0]) : 0
        var ry = refWin && Array.isArray(refWin.position) ? root.numOr(refWin.position[1]) : 0
        var mx = memberWin && Array.isArray(memberWin.position) ? root.numOr(memberWin.position[0]) : 0
        var my = memberWin && Array.isArray(memberWin.position) ? root.numOr(memberWin.position[1]) : 0
        var dx = rx - mx
        var dy = ry - my
        if (Math.abs(dx) >= Math.abs(dy)) return dx < 0 ? "l" : "r"
        return dy < 0 ? "u" : "d"
    }

    // Build the restore-script lines that reform one group member into its
    // group: the first member to resolve (matched synchronously, or
    // discovered later by the Phase 3b safety net) becomes the group's
    // anchor address; every later member is merged into it via a directional
    // group-move. addrExpr is either a literal hyprctl address (matched
    // windows, known at build time) or a shell variable reference like "$A"
    // (spawned windows, resolved at runtime by the safety net) - both are
    // embedded verbatim into the generated bash/dispatch text.
    function groupMergeLines(addrExpr, groupId, dir, indent) {
        var pad = indent || ""
        var varName = "GRP" + groupId + "_ADDR"
        return [
            pad + "if [ -z \"${" + varName + ":-}\" ]; then",
            pad + "  export " + varName + "=\"" + addrExpr + "\"",
            pad + "else",
            pad + "  echo \"[group-merge] gid=" + groupId + " addr=" + addrExpr + " dir=" + dir + "\" >> \"$LOGFILE\"",
            pad + "  hyprctl dispatch \"hl.dsp.window.move({window='address:" + addrExpr + "', into_group='" + dir + "'})\" 2>>\"$LOGFILE\" || true",
            pad + "fi"
        ]
    }

    function resolveExe(className) {
        return className.toLowerCase()
    }

    // Return the browser engine for a window class: "firefox", "chromium", or
    // null if the window isn't a supported browser. Mirrors the pure helper in
    // restoreLogic.mjs (kept in sync for the QML-side detection).
    function browserTypeForClass(cls) {
        if (typeof cls !== "string" || cls.length === 0) return null
        if (/^(firefox|librewolf|waterfox|floorp|tor-browser|zen|palemoon|seamonkey)(\.|-|$)/i.test(cls)) return "firefox"
        if (/(chrom|brave|vivaldi|edge|opera|electron)/i.test(cls)) return "chromium"
        return null
    }

    // Resolve the profile/user-data directory for a browser window from its
    // captured /proc cmdline. For Chromium this is the --user-data-dir value
    // (or the default ~/.config/<app>); for Firefox the -P/-profile path or the
    // default ~/.mozilla/firefox/<default-profile>. Returns a safe-ish absolute
    // path or null. Never used in shell generation - only to locate the
    // session/debug files for tab capture.
    function resolveBrowserProfile(btype, cmdline) {
        var home = Quickshell.env("HOME")
        var cmd = String(cmdline || "")
        var m
        if (btype === "chromium") {
            m = /--user-data-dir=("?)([^"\s]+)\1/.exec(cmd)
            if (m) return m[2]
            if (/google-chrome/i.test(cmd)) return home + "/.config/google-chrome"
            if (/chromium/i.test(cmd)) return home + "/.config/chromium"
            if (/brave/i.test(cmd)) return home + "/.config/BraveSoftware/Brave-Browser"
            if (/vivaldi/i.test(cmd)) return home + "/.config/vivaldi"
            if (/edge/i.test(cmd)) return home + "/.config/microsoft-edge"
            if (/opera/i.test(cmd)) return home + "/.config/opera"
            return null
        } else if (btype === "firefox") {
            m = /--profile(=|\s+)(\S+)/.exec(cmd)
            if (m) return m[2]
            m = /-P\s+(\S+)/.exec(cmd)
            if (m) return home + "/.mozilla/firefox/" + m[1]
            // Default: pick the default* profile dir if present.
            var base = home + "/.mozilla/firefox"
            return base
        }
        return null
    }

    // --- Bar Button ---

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "󰆞"
        onPressed: function(b) {
            root.toggle()
        }
    }

    // --- Popup Panel ---

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        contentWidth: 280
        contentHeight: showingNameInput ? 220 : 400

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
        }

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 8
            visible: !root.showingNameInput

            PanelHero {
                title: root.isRestoring ? "Restoring..." : "Workspace Restorer"
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Qt.darker(Color.bar.text, 1.15)
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: root.isRestoring ? Qt.darker(Color.bar.background, 1.15) : root.hoverBg

                Row {
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        text: root.isSnapshotting ? "󰏇" : root.isRestoring ? "󰑐" : "󰅧"
                        color: Color.bar.text
                        font.pixelSize: 14
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: root.isSnapshotting ? "Capturing..." : root.isRestoring ? "Restoring..." : "Take Snapshot"
                        color: Color.bar.text
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    enabled: !root.isRestoring && !root.isSnapshotting
                    onContainsMouseChanged: parent.color = containsMouse ? root.selectedBg : root.hoverBg
                    onClicked: root.doSnapshot()
                }
            }

            PanelSectionHeader { text: "Profiles" }

            Column {
                width: parent.width
                spacing: 4

                Repeater {
                    model: root.profiles

                    // Each entry is {name, comment} (see refreshProfiles/
                    // listProc) - comment is the optional multiline note
                    // captured on the save screen, shown here as a one-line
                    // preview (full text on hover) so a later restore can be
                    // matched to the right snapshot.
                    delegate: Column {
                        width: parent.width
                        spacing: 2

                        Rectangle {
                            width: parent.width
                            height: 36
                            radius: Style.cornerRadius
                            color: Qt.darker(Color.bar.background, 1.05)

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 6
                                spacing: 6

                                Text {
                                    text: root.profileIconFor(modelData.name)
                                    color: Qt.darker(Color.bar.text, 1.4)
                                    font.pixelSize: 13
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                Text {
                                    text: modelData.name
                                    color: Color.bar.text
                                    font.family: Style.font.family
                                    font.pixelSize: Style.font.body
                                    Layout.alignment: Qt.AlignVCenter
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        hoverEnabled: true
                                        enabled: !root.isRestoring && !root.isSnapshotting
                                        onContainsMouseChanged: parent.parent.parent.color = containsMouse ? root.hoverBg : Qt.darker(Color.bar.background, 1.05)
                                        onClicked: root.doRestore(modelData.name)

                                        ToolTip.visible: containsMouse && modelData.comment.length > 0
                                        ToolTip.delay: 400
                                        ToolTip.text: modelData.comment
                                    }
                                }

                                Text {
                                    text: "󰆴"
                                    color: Qt.darker(Color.bar.text, 1.4)
                                    font.pixelSize: 13
                                    Layout.alignment: Qt.AlignVCenter

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        hoverEnabled: true
                                        enabled: !root.isRestoring && !root.isSnapshotting
                                        onContainsMouseChanged: parent.parent.parent.color = containsMouse ? "#663333" : "transparent"
                                        onClicked: root.doDelete(modelData.name)
                                    }
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            leftPadding: 8
                            visible: modelData.comment.length > 0
                            text: modelData.comment.split("\n")[0]
                            color: Qt.darker(Color.bar.text, 1.7)
                            font.family: Style.font.family
                            font.pixelSize: Math.max(9, Style.font.body - 3)
                            font.italic: true
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            Item { width: 1; height: 4 }

            Text {
                text: root.lastAction
                color: Qt.darker(Color.bar.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.italic: true
                visible: root.lastAction !== ""
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
            }
        }

        // --- Name Input View ---

        Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 10
            visible: root.showingNameInput

            PanelHero {
                title: "Save Snapshot"
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Qt.darker(Color.bar.text, 1.15)
            }

            TextField {
                id: saveNameField
                width: parent.width
                height: 36
                placeholderText: "Profile name"
                color: Color.bar.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                leftPadding: 10
                background: Rectangle {
                    color: Qt.darker(Color.bar.background, 1.08)
                    radius: Style.cornerRadius
                    border.color: Qt.darker(Color.bar.text, 1.15)
                    border.width: 1
                }
                Keys.onReturnPressed: confirmSave()
                Keys.onEnterPressed: confirmSave()
            }

            // Optional multiline note, shown as a one-line preview (full text
            // on hover) beside the profile name in the list below, so a
            // later restore can be matched to the right snapshot. Return
            // inserts a newline here rather than submitting - only the Save
            // button (or its own Enter-less TextArea default) confirms.
            TextArea {
                id: commentField
                width: parent.width
                height: 70
                placeholderText: "Notes (optional) - what's in this snapshot?"
                color: Color.bar.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                leftPadding: 10
                topPadding: 8
                wrapMode: TextArea.Wrap
                background: Rectangle {
                    color: Qt.darker(Color.bar.background, 1.08)
                    radius: Style.cornerRadius
                    border.color: Qt.darker(Color.bar.text, 1.15)
                    border.width: 1
                }
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: root.hoverBg

                Text {
                    anchors.centerIn: parent
                    text: "  Save"
                    color: Color.bar.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onContainsMouseChanged: parent.color = containsMouse ? root.selectedBg : root.hoverBg
                    onClicked: confirmSave()
                }
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Style.cornerRadius
                color: Qt.darker(Color.bar.background, 1.05)

                Text {
                    anchors.centerIn: parent
                    text: "Cancel"
                    color: Qt.darker(Color.bar.text, 1.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onContainsMouseChanged: parent.color = containsMouse ? Qt.darker(Color.bar.text, 1.1) : Qt.darker(Color.bar.background, 1.05)
                    onClicked: {
                        root.showingNameInput = false
                        root.pendingSnapshot = null
                        commentField.text = ""
                        root.lastAction = "Snapshot discarded"
                    }
                }
            }
        }
    }

    // --- Profile Listing ---

    function refreshProfiles() {
        listProc.command = ["python3", root.storeScript, "list", root.profileDir]
        listProc.running = true
    }

    Process {
        id: listProc
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // The helper emits a JSON array of {name, comment} (name
                // already validated server-side, capped at 256 entries; a
                // missing/invalid comment comes back as "").
                try {
                    var entries = JSON.parse(text)
                    root.profiles = Array.isArray(entries) ? entries : []
                } catch (e) {
                    root.profiles = []
                }
            }
        }
    }

    // --- Snapshot ---

    function doSnapshot() {
        // Guard against re-entrancy: a second snapshot while the async capture
        // chain is in flight would interleave state and corrupt the result.
        if (root.isSnapshotting) return
        root.isSnapshotting = true
        root.lastAction = "Capturing..."
        snapClientsProc.running = true
    }

    Process {
        id: snapClientsProc
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var clients = JSON.parse(text)
                    var pids = []
                    var seen = {}
                    for (var p = 0; p < clients.length; p++) {
                        if (!seen[clients[p].pid]) {
                            seen[clients[p].pid] = true
                            pids.push(clients[p].pid)
                        }
                    }
                    snapCmdlinesProc._clients = clients
                    // Robust per-PID capture. Each PID emits one line of
                    // "PID<TAB>cmdline<TAB>cwd". Fields are matched BY PID (not
                    // by array index), so a failed /proc read can never shift
                    // other windows' data (the old plain-text approach slid on
                    // any /proc failure). Tabs/newlines inside values are
                    // collapsed to spaces to keep the TSV format stable.
                    snapCmdlinesProc.command = ["bash", "-lc",
                        "pids=\"" + pids.join(" ") + "\"; " +
                        "for p in $pids; do " +
                        "  cmd=$(cat /proc/$p/cmdline 2>/dev/null | tr '\\0' ' ' | tr '\\t\\n' '  ' | sed 's/ *$//'); " +
                        "  cwd=$(readlink /proc/$p/cwd 2>/dev/null | tr '\\t\\n' '  '); " +
                        "  printf '%s\\t%s\\t%s\\n' \"$p\" \"$cmd\" \"$cwd\"; " +
                        "done"]
                    snapCmdlinesProc.running = true
                } catch(e) {
                    root.isSnapshotting = false
                    root.lastAction = "Failed to capture windows"
                }
            }
        }
    }

    Process {
        id: snapCmdlinesProc
        property var _clients: null
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var clients = snapCmdlinesProc._clients
                try {
                    var infoMap = {}
                    var lines = (text || "").split("\n")
                    for (var l = 0; l < lines.length; l++) {
                        var line = lines[l].trim()
                        if (!line) continue
                        var parts = line.split("\t")
                        if (parts.length >= 1) {
                            var rec = { pid: parts[0], cmdline: parts[1] || "", cwd: parts[2] || "" }
                            infoMap[rec.pid] = rec
                        }
                    }
                    for (var i = 0; i < clients.length; i++) {
                        var info = infoMap[String(clients[i].pid)]
                        clients[i]._cmdline = (info && info.cmdline) ? info.cmdline.trim() : null
                        clients[i]._cwd = (info && info.cwd) ? info.cwd.trim() : null
                    }
                } catch(e) {
                    for (var k = 0; k < clients.length; k++) {
                        clients[k]._cmdline = null
                        clients[k]._cwd = null
                    }
                }
                snapMonitorsProc._clients = clients
                snapMonitorsProc.running = true
            }
        }
    }

    Process {
        id: snapMonitorsProc
        property var _clients: null
        command: ["hyprctl", "-j", "monitors"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var monitors = JSON.parse(text)
                    var clients = snapMonitorsProc._clients

                    var monMap = {}
                    for (var m = 0; m < monitors.length; m++) {
                        monMap[monitors[m].id] = monitors[m].name
                    }

                    var windows = []

                    // Clean a captured /proc cmdline into a safe relaunch string:
                    // collapses internal whitespace (single spaces) and trims.
                    function cleanCmd(raw) {
                        if (!raw) return null
                        var v = raw.replace(/\s+/g, " ").trim()
                        return v.length ? v : null
                    }

                    // Command cache per PID. Multiple split-screen windows from
                    // one process (e.g. two nautilus windows sharing a PID)
                    // must ALL get the same launch command - otherwise a later
                    // window falls back to className, which can't reopen it.
                    // For single-instance apps the captured cmdline already
                    // carries the right flag (e.g. "nautilus --new-window").
                    var pidCmd = {}

                    // Which windows were tabbed together (grouped), and in
                    // what order, so restore can reform the same groups.
                    var groupMeta = root.buildGroupMeta(clients)

                    for (var i = 0; i < clients.length; i++) {
                        var c = clients[i]
                        var monName = monMap[c.monitor] || String(c.monitor)

                        var cmd = pidCmd[c.pid]
                        if (cmd === undefined) {
                            cmd = cleanCmd(c._cmdline)
                            pidCmd[c.pid] = cmd === null ? null : cmd
                        }

                        // Browser detection: mark the window so the tab-capture
                        // pass (snapTabsProc) can enrich it later, and resolve
                        // the profile/user-data dir from the command line. This
                        // is done here (per window) so tabs are attached to the
                        // right window and restore can reopen them in place.
                        var btype = root.browserTypeForClass(c.class)
                        var bprofile = btype ? root.resolveBrowserProfile(btype, c._cmdline) : null
                        var gm = groupMeta[c.address]

                        windows.push({
                            "class": c.class,
                            "title": c.title,
                            "pid": c.pid,
                            "address": c.address,
                            "workspace": c.workspace.name,
                            "workspaceId": c.workspace.id,
                            "monitor": monName,
                            "monitorId": c.monitor,
                            "command": cmd,
                            "cwd": c._cwd ? c._cwd.trim() : null,
                            "position": [c.at[0], c.at[1]],
                            "size": [c.size[0], c.size[1]],
                            "splitRatio": c.splitratio,
                            "floating": c.floating,
                            "fullscreen": c.fullscreen,
                            "browser": btype,
                            "browserProfile": bprofile,
                            "tabs": null,
                            "groupId": gm ? gm.groupId : null,
                            "groupOrder": gm ? gm.groupOrder : null
                        })
                    }
                    snapTabsProc._windows = windows
                    root._monitorsCaptured = monitors
                    snapTabsProc.begin()
                } catch(e) {
                    root.isSnapshotting = false
                    root.lastAction = "Failed to capture monitors"
                    console.error("WSRESTORE snapMonitors error:", String(e && e.stack || e), "| lastAction=", root.lastAction)
                }
            }
        }
    }

    // Tab-capture pass. After windows are assembled, run the per-browser
    // tab capture (Firefox session file / Chromium CDP; see scripts/capture_tabs.py)
    // for each unique browser profile, then finalize pendingSnapshot. Tabs are
    // attached to the first window of each profile so restore won't reopen the
    // same pages from multiple windows sharing one browser process.
    Process {
        id: snapTabsProc
        property var _windows: []
        property var _results: {}

        // Build and run the capture for every unique browser profile.
        function begin() {
            snapTabsProc.command = []
            snapTabsProc._results = {}
            var windows = snapTabsProc._windows
            var script = Qt.resolvedUrl("scripts/capture_tabs.py").toString().replace(/^file:\/\//, "")
            var seen = {}
            var invocations = []
            for (var i = 0; i < windows.length; i++) {
                var w = windows[i]
                if (!w.browser || !w.browserProfile) continue
                var key = w.browser + "\u0001" + w.browserProfile
                if (seen[key]) continue
                seen[key] = true
                invocations.push("python3 " + root.shellArg(script) + " " +
                    root.shellArg(w.browser) + " " + root.shellArg(w.browserProfile) + " " +
                    root.shellArg(key))
            }
            if (invocations.length === 0) {
                snapTabsProc.finishNow()
                return
            }
            snapTabsProc.command = ["bash", "-lc", invocations.join("; ")]
            snapTabsProc.running = true
        }

        function finishNow() {
            root.pendingSnapshot = snapTabsProc.assemble()
            root.isSnapshotting = false
            root.lastAction = "Captured " + snapTabsProc._windows.length + " windows"
            saveNameField.text = generateDefaultName()
            commentField.text = ""
            root.showingNameInput = true
        }

        // Build pendingSnapshot, attaching parsed tab data onto windows.
        function assemble() {
            var windows = snapTabsProc._windows
            var results = snapTabsProc._results || {}
            var attached = {}
            for (var i = 0; i < windows.length; i++) {
                var w = windows[i]
                if (!w.browser || !w.browserProfile) continue
                var key = w.browser + "\u0001" + w.browserProfile
                if (attached[key]) continue
                attached[key] = true
                var res = results[key]
                if (res && res.ok && Array.isArray(res.tabs)) {
                    w.tabs = res.tabs
                } else {
                    w.tabs = []
                }
            }
            return {
                "timestamp": Date.now(),
                "windows": windows,
                "monitors": root._monitorsCaptured || []
            }
        }

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                // Each line is one JSON object from the helper, routed by its
                // embedded _profile key (set by the capture script).
                var results = {}
                var linesOut = (text || "").split("\n")
                for (var r = 0; r < linesOut.length; r++) {
                    var ln = linesOut[r].trim()
                    if (!ln) continue
                    try {
                        var o = JSON.parse(ln)
                        if (o && o._profile) results[o._profile] = o
                    } catch(e) {}
                }
                // Snapshot the monitors from the last stage (stored on root).
                snapTabsProc._results = results
                snapTabsProc.finishNow()
            }
        }
    }

    // Monitor list captured by the monitors stage, stashed for the final
    // profile assembly (kept on root so snapTabsProc.assemble can read it).
    // --- Save ---

    function doSave(name, comment) {
        if (!root.pendingSnapshot || name.length === 0) return
        var safe = root.sanitizeProfileName(name)
        if (safe === null) {
            root.lastAction = "Invalid profile name"
            return
        }
        root.pendingSnapshot.comment = root.sanitizeComment(comment)
        var json = JSON.stringify(root.pendingSnapshot, null, 2)
        // The store helper reads the JSON from stdin (never a temp file or a
        // shell heredoc). payload size is bounded by the helper; enforcement
        // of cardinality happens both here and inside the helper.
        if (root.enforceProfileCardinality(root.pendingSnapshot) === null) {
            root.lastAction = "Snapshot exceeded limits"
            return
        }
        saveProc._json = json
        saveProc.stdinEnabled = true
        saveProc.command = ["python3", root.storeScript, "save", root.profileDir, safe]
        saveProc.running = true
    }

    Process {
        id: saveProc
        property string _json: ""
        command: []
        stdinEnabled: true
        onStarted: {
            saveProc.write(saveProc._json)
            saveProc.stdinEnabled = false
        }
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                // Keep pendingSnapshot so the user can retry; never report success.
                root.lastAction = "Failed to save profile"
                root.notify("Failed to save", "Could not write profile file")
                return
            }
            root.lastAction = "Profile saved"
            root.pendingSnapshot = null
            root.showingNameInput = false
            root.refreshProfiles()
            root.notify("Snapshot saved", saveNameField.text)
        }
    }

    // --- Restore ---

    function doRestore(name) {
        if (root.isRestoring) return
        var safe = root.sanitizeProfileName(name)
        if (safe === null) {
            root.isRestoring = false
            root.lastAction = "Invalid profile name"
            return
        }
        root.isRestoring = true
        root.lastAction = "Restoring..."
        restoreProc.command = ["python3", root.storeScript, "load", root.profileDir, safe]
        restoreProc.running = true
    }

    Process {
        id: restoreProc
        command: []
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    // Loading runs through the store helper, which revalidates
                    // the JSON and its cardinality (bounded, no-follow read) —
                    // here we additionally enforce the same caps before any
                    // launch command is generated from the content.
                    var profile = JSON.parse(text)
                    if (root.enforceProfileCardinality(profile) === null) {
                        root.isRestoring = false
                        root.lastAction = "Failed to load profile"
                        return
                    }
                    restoreWithConflicts(profile)
                } catch(e) {
                    root.isRestoring = false
                    root.lastAction = "Failed to load profile"
                }
            }
        }
    }

    function restoreWithConflicts(profile) {
        if (!profile || !profile.windows || profile.windows.length === 0) {
            root.isRestoring = false
            root.lastAction = "Profile is empty"
            return
        }
        checkExistingProc._profile = profile
        checkExistingProc.running = true
    }

    Process {
        id: checkExistingProc
        property var _profile: null
        command: ["hyprctl", "-j", "clients"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var existing = []
                try {
                    existing = JSON.parse(text)
                } catch(e) {
                    existing = []
                }
                root.buildAndRunRestore(checkExistingProc._profile, existing)
            }
        }
    }

    Process {
        id: masterRestoreProc
        property int _count: 0
        command: ["bash", "-c", ""]
        onExited: function(exitCode) {
            root.isRestoring = false
            if (exitCode !== 0) {
                root.lastAction = "Restore failed"
                root.notify("Restore failed", "Not all windows could be restored")
                return
            }
            root.lastAction = "Restored " + _count + " windows"
            root.notify("Workspace restored", _count + " windows launched")
        }
    }

    // Bash lines that put things back the way they were before this restore
    // touched anything: refocus the workspace that was active (ORIG_WORKSPACE,
    // captured up front in buildAndRunRestore), then reconcile the scratchpad/
    // special-workspace open-or-closed state (ORIG_SPECIAL) on whichever
    // monitor is now focused. toggle_special only *toggles* - it can't be set
    // directly - so this only calls it when the current state actually
    // differs from the captured one, closing whatever's open now and/or
    // reopening what was open before, bare special-workspace names only
    // ([A-Za-z0-9_]{1,32}, stripped of the "special:" prefix) so a stray
    // character from hyprctl's own output can never break out of the Lua
    // string literal passed to hyprctl dispatch. Used at both points a
    // restore can finish: right after Phase 3 when there's no safety pass, or
    // at the end of the safety pass when there is one - whichever runs last.
    function restoreOrigFocusLines(indent) {
        var pad = indent || ""
        return [
            pad + "[ -n \"$ORIG_WORKSPACE\" ] && hyprctl dispatch \"hl.dsp.focus({workspace='$ORIG_WORKSPACE'})\" 2>>\"$LOGFILE\" || true",
            pad + "CUR_SPECIAL=$(hyprctl monitors -j 2>/dev/null | jq -r '([.[] | select(.focused==true) | .specialWorkspace.name][0]) // \"\"' 2>/dev/null)",
            pad + "if [ \"$CUR_SPECIAL\" != \"$ORIG_SPECIAL\" ]; then",
            pad + "  CNAME=\"${CUR_SPECIAL#special:}\"",
            pad + "  ONAME=\"${ORIG_SPECIAL#special:}\"",
            pad + "  [[ \"$CNAME\" =~ ^[A-Za-z0-9_]{1,32}$ ]] || CNAME=\"\"",
            pad + "  [[ \"$ONAME\" =~ ^[A-Za-z0-9_]{1,32}$ ]] || ONAME=\"\"",
            pad + "  [ -n \"$CNAME\" ] && hyprctl dispatch \"hl.dsp.workspace.toggle_special('$CNAME')\" 2>>\"$LOGFILE\" || true",
            pad + "  [ -n \"$ONAME\" ] && hyprctl dispatch \"hl.dsp.workspace.toggle_special('$ONAME')\" 2>>\"$LOGFILE\" || true",
            pad + "fi"
        ]
    }

    // Build and run the restore script. Extracted into its own function so the
    // whole construction is wrapped in try/catch: any unexpected throw here
    // must reset isRestoring, or the widget stays stuck in "Restoring..."
    // forever with no way to recover except restarting the shell.
    function buildAndRunRestore(profile, existing) {
        try {
            var lines = ["#!/bin/bash"]
            // WSROOT is exported by the outer launcher (a private mktemp -d).
            // Everything this restore writes - log, launch scripts, safety
            // script - lives inside it, never in shared /tmp. The private dir
            // is removed on exit unless the detached safety pass owns cleanup.
            lines.push("LOGFILE=\"$WSROOT/restore.log\"")
            lines.push("SAFETY_OWNED=0")
            lines.push("trap 'if [ \"$SAFETY_OWNED\" != \"1\" ]; then rm -rf \"$WSROOT\"; fi' EXIT")
            lines.push("echo \"[start] wsroot=$WSROOT profile_windows=" + profile.windows.length + " existing=" + (existing ? existing.length : 0) + "\" >> \"$LOGFILE\"")

            // Phase 3/3b focus each spawn's target workspace in turn so the
            // new window lands there, which leaves whichever workspace was
            // targeted last as the active one. Remember what was actually
            // active before any of that happens, so it can be refocused once
            // all of this restore's work is done (see the two refocus points
            // below: right after Phase 3 when there's no safety pass, or at
            // the end of the safety pass when there is one).
            lines.push("ORIG_WORKSPACE=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.name' 2>/dev/null)")
            lines.push("export ORIG_WORKSPACE")

            // Special workspaces (e.g. the scratchpad) overlay on top of the
            // focused monitor's normal workspace and are toggled open/closed
            // independently of it - hyprctl reports the open one (if any) as
            // that monitor's specialWorkspace.name (e.g. "special:scratchpad",
            // or "" when none is open). Remember whether one was open before
            // the restore touches anything, so it can be put back at the same
            // two points ORIG_WORKSPACE is refocused (see restoreOrigFocusLines).
            lines.push("ORIG_SPECIAL=$(hyprctl monitors -j 2>/dev/null | jq -r '([.[] | select(.focused==true) | .specialWorkspace.name][0]) // \"\"' 2>/dev/null)")
            lines.push("export ORIG_SPECIAL")

            // Computed up front (used both to gate the auto_group guard below
            // and by Phase 2b2 further down) so we only touch the Hyprland
            // config when this profile actually has groups to reform.
            var restoreGroups = root.buildRestoreGroups(profile.windows)
            var hasGroups = restoreGroups.length > 0

            // Hyprland's group:auto_group (on by default) auto-joins a newly
            // mapped window into whatever group is currently active on its
            // workspace. Phase 3 below launches several windows onto the same
            // workspace in quick succession, so with auto_group left on,
            // Hyprland can silently group unrelated windows together and
            // fight the explicit group-merges in Phase 2b2/3b. Save the
            // current value and force it off for the duration of the
            // restore; it's turned back on wherever this restore's work
            // actually finishes (see the safety-pass trap below, or right
            // after Phase 2b2 when there's no safety pass).
            if (hasGroups) {
                lines.push("ORIG_AUTOGROUP=$(hyprctl getoption group:auto_group -j 2>/dev/null | jq -r 'if .bool then 1 else 0 end' 2>/dev/null)")
                lines.push("[ -z \"$ORIG_AUTOGROUP\" ] && ORIG_AUTOGROUP=1")
                lines.push("export ORIG_AUTOGROUP")
                lines.push("hyprctl keyword group:auto_group 0 2>>\"$LOGFILE\" || true")
            }

            // Track which profile windows have been matched
            var matched = []
            for (var p = 0; p < profile.windows.length; p++) matched[p] = false

            var toMove = []
            var toFloat = []
            var matchedAddrs = []
            // Profile window index -> live address, for windows matched to an
            // already-open window (known synchronously, unlike spawned windows
            // whose address is only discovered later by the safety net).
            var matchedAddrByIndex = {}
            // Addresses of currently-open browser windows whose snapshot had
            // captured tabs. These are closed (so the browser process quits)
            // before we relaunch it fresh with exactly the snapshot's tabs.
            // This avoids running-browser CLI quirks (Firefox one-window-per-URL,
            // Vivaldi session-restore extras) and workspace-focus slippage.
            var browserCloseAddrs = []

            if (existing && existing.length > 0) {
                for (var i = 0; i < existing.length; i++) {
                    var e = existing[i]
                    var bestIdx = -1

                    // Match by class, then title for duplicates.
                    // Only claim the first unmatched class hit as a fallback,
                    // and only overwrite it on an exact title match - otherwise
                    // repeated scans keep clobbering bestIdx with the LAST
                    // same-class window instead of a stable pick.
                    for (var p = 0; p < profile.windows.length; p++) {
                        if (matched[p]) continue
                        if (e.class === profile.windows[p].class) {
                            if (bestIdx === -1) bestIdx = p
                            if (e.title === profile.windows[p].title) {
                                bestIdx = p
                                break
                            }
                        }
                    }

                    if (bestIdx >= 0) {
                        var target = profile.windows[bestIdx]
                        // Browser snapshot windows with captured tabs are
                        // relaunched fresh: close the existing matching window so
                        // the browser process exits, then let Phase 3 spawn one
                        // clean window with exactly the snapshot's tabs. Leave
                        // matched[] false so Phase 3 spawns this window.
                        if (target.browser && target.tabs && target.tabs.length > 0) {
                            browserCloseAddrs.push(e.address)
                            continue
                        }
                        matched[bestIdx] = true
                        matchedAddrs.push(e.address)
                        matchedAddrByIndex[bestIdx] = e.address
                        var tws = root.safeWorkspace(target.workspace)
                        // Move to correct workspace if needed
                        if (tws !== null && String(e.workspace.name) !== String(target.workspace)) {
                            toMove.push({addr: e.address, ws: tws, cls: e.class, splitRatio: target.splitRatio, fullscreen: target.fullscreen, e_floating: e.floating, e_fullscreen: e.fullscreen})
                        }
                        // Restore floating state and position only if it differs
                        // from the window's current state, so "toggle" never
                        // leaves an already-floating window de-floated.
                        if (target.floating) {
                            toFloat.push({addr: e.address, pos: target.position, size: target.size, e_floating: e.floating, e_fullscreen: e.fullscreen})
                        }
                    } else {
                        // Unmatched existing window: left untouched (we no
                        // longer SIGKILL unmatched windows).
                    }
                }
            }

            // Phase 0: Pin every snapshotted workspace to the monitor it
            // was on at capture time. Do this BEFORE anything moves into
            // those workspaces - Hyprland workspaces are global, not
            // monitor-scoped, so a workspace not yet anchored to a monitor
            // gets claimed by whichever monitor is focused when the first
            // window lands in it (multi-monitor setups).
            var wsToMonitor = {}
            for (var wm = 0; wm < profile.windows.length; wm++) {
                var pws = root.safeWorkspace(profile.windows[wm].workspace)
                var pmon = profile.windows[wm].monitor
                if (pws !== null && pmon && /^[A-Za-z0-9-]{1,64}$/.test(pmon)) {
                    wsToMonitor[pws] = pmon
                }
            }
            for (var wsName in wsToMonitor) {
                if (!wsToMonitor[wsName]) continue
                lines.push("echo \"[pin] ws=" + wsName + " monitor=" + wsToMonitor[wsName] + "\" >> \"$LOGFILE\"")
                lines.push("hyprctl dispatch \"hl.dsp.workspace.move({workspace='" + wsName + "', monitor='" + wsToMonitor[wsName] + "'})\" 2>>\"$LOGFILE\" || true")
            }

            // Phase 1: Removed. We no longer SIGKILL unmatched windows and
            // no longer delete browser session caches - both were
            // destructive and could be driven by a crafted profile. Restore
            // now only moves matched windows and spawns missing ones.

            // Phase 2: Move matched windows to correct workspaces
            for (var m = 0; m < toMove.length; m++) {
                var mv = toMove[m]
                lines.push("echo \"[move-existing] ws=" + mv.ws + " addr=" + mv.addr + "\" >> \"$LOGFILE\"")
                lines.push("hyprctl dispatch \"hl.dsp.window.move({workspace='" + mv.ws + "', window='address:" + mv.addr + "', follow=false})\" 2>>\"$LOGFILE\" || true")
                // Restore fullscreen only if the target was captured fullscreen
                // AND the existing window isn't already fullscreen (avoids
                // leaving the user stuck in fullscreen unexpectedly).
                if (mv.fullscreen && !mv.e_fullscreen) {
                    lines.push("hyprctl dispatch \"hl.dsp.window.fullscreen({mode='fullscreen', window='address:" + mv.addr + "'})\" 2>>\"$LOGFILE\" || true")
                }
            }

            // Phase 2b: Apply floating state and positioning
            for (var f = 0; f < toFloat.length; f++) {
                var fl = toFloat[f]
                var fx = root.numOr(fl.pos[0])
                var fy = root.numOr(fl.pos[1])
                var fw = root.numOr(fl.size[0])
                var fh = root.numOr(fl.size[1])
                // Only toggle floating when the window's current state differs
                // from the target's captured state, so an already-floating
                // window is not un-floated.
                if (!fl.e_floating) {
                    lines.push("hyprctl dispatch \"hl.dsp.window.float({action='toggle', window='address:" + fl.addr + "'})\" 2>>\"$LOGFILE\" || true")
                }
                lines.push("hyprctl dispatch \"hl.dsp.window.move({x=" + fx + ", y=" + fy + ", relative=false, window='address:" + fl.addr + "'})\" 2>>\"$LOGFILE\" || true")
                lines.push("hyprctl dispatch \"hl.dsp.window.resize({x=" + fw + ", y=" + fh + ", window='address:" + fl.addr + "'})\" 2>>\"$LOGFILE\" || true")
            }

            // Phase 2b2: Reform window groups (tabbed windows). For every
            // profile group with 2+ members, whichever member resolves first
            // - matched here synchronously, or discovered later by the
            // Phase 3b safety net - becomes that group's anchor address;
            // every later member is merged into it via a directional
            // group-move (see groupMergeLines). Members skipped as unsafe
            // metadata, or whose relaunch fails, simply never resolve and the
            // group forms from whichever members did.
            var groupDirByMember = {}
            var groupIdByMemberIdx = {}
            for (var rg = 0; rg < restoreGroups.length; rg++) {
                var grp = restoreGroups[rg]
                var refWin = profile.windows[grp.refIndex]
                for (var gm = 0; gm < grp.members.length; gm++) {
                    var memberIdx = grp.members[gm]
                    var dir = root.mergeDirectionFor(refWin, profile.windows[memberIdx])
                    groupDirByMember[memberIdx] = dir
                    groupIdByMemberIdx[memberIdx] = grp.groupId
                    var knownAddr = matchedAddrByIndex[memberIdx]
                    if (knownAddr) {
                        var gLines = root.groupMergeLines(knownAddr, grp.groupId, dir, "")
                        for (var gl = 0; gl < gLines.length; gl++) lines.push(gLines[gl])
                    }
                }
            }

            // Phase 2c: Close existing browser windows whose snapshot carried
            // captured tabs. Closing them makes the browser process exit; the
            // relaunch in Phase 3 then starts it fresh so `browser url1 url2`
            // opens exactly one window with the snapshot's tabs. Wait briefly
            // for the process to fully quit so the fresh launch isn't
            // forwarded to the dying instance.
            if (browserCloseAddrs.length > 0) {
                for (var bc = 0; bc < browserCloseAddrs.length; bc++) {
                    lines.push("echo \"[close-browser] addr=" + browserCloseAddrs[bc] + "\" >> \"$LOGFILE\"")
                    lines.push("hyprctl dispatch \"hl.dsp.window.close({window='address:" + browserCloseAddrs[bc] + "'})\" 2>>\"$LOGFILE\" || true")
                }
                lines.push("sleep 1.5")
            }

            // Phase 3: Spawn missing windows directly onto their target
            // workspace. Strategy: focus the target workspace FIRST, then
            // launch - so each window opens where it belongs instead of
            // piling onto the currently focused workspace and relying on a
            // fragile later move. This is far more reliable for both
            // single and duplicate-class windows.
            var spawnCount = 0
            var spawnTargets = []
            for (var j = 0; j < profile.windows.length; j++) {
                if (!matched[j]) {
                    var w = profile.windows[j]
                    var ws = root.safeWorkspace(w.workspace)
                    var cls = root.safeClass(w.class)
                    if (ws === null || cls === null) {
                        // Ignore entries whose metadata can't be represented
                        // safely rather than risk injection in generated code.
                        lines.push("echo \"[launch] skipped unsafe metadata\" >> \"$LOGFILE\"")
                        continue
                    }
                    var cmd = root.sanitizeLaunchCommand(w.command, cls)

                    // For browser windows with captured tabs, append the page
                    // For browser windows with captured tabs, produce the launch
                    // commands (which may be several, e.g. Firefox opens a single
                    // new window then adds tabs) that reopen the pages in place.
                    var cmds
                    if (w.browser && (w.tabs && w.tabs.length > 0)) {
                        cmds = root.buildBrowserLaunchCommands(cmd, cls, w.tabs)
                    } else {
                        cmds = cmd.length > 0 ? [cmd] : []
                    }

                    // Launch file: one (already shell-quoted) exec line per step.
                    if (cmds.length === 0) {
                        lines.push("echo \"[launch] no safe command for ws=" + ws + "\" >> \"$LOGFILE\"")
                    }
                    var steps = []
                    for (var k = 0; k < cmds.length; k++) {
                        if (k === 0 && cmds.length === 1) {
                            steps.push("exec " + cmds[k])
                        } else if (k === 0) {
                            steps.push(cmds[k] + " &")
                        } else {
                            steps.push(cmds[k])
                        }
                        if (k < cmds.length - 1) steps.push("sleep 0.4")
                    }
                    var launchline = steps.length > 0 ? steps.join("\n") : "exit 1"
                    lines.push("SPATH=\"$WSROOT/spawn-" + j + ".sh\"")
                    lines.push("printf '#!/bin/bash\\n%s\\n' " + root.shellArg(launchline) + " > \"$SPATH\" && chmod 700 \"$SPATH\"")
                    // Focus the target workspace so the window lands on it
                    lines.push("hyprctl dispatch \"hl.dsp.focus({workspace='" + ws + "'})\" 2>>\"$LOGFILE\" || true")
                    lines.push("sleep 0.3")
                    lines.push("bash \"$SPATH\" &")
                    lines.push("echo \"[launch] ws=" + ws + " cmd='$SPATH'\" >> \"$LOGFILE\"")

                    // Track for a class-based safety re-check pass
                    spawnTargets.push({
                        cls: cls,
                        ws: ws,
                        floating: w.floating,
                        fullscreen: w.fullscreen,
                        splitRatio: w.splitRatio,
                        pos: w.position,
                        size: w.size,
                        pIndex: j
                    })
                    spawnCount++
                }
            }

            // Phase 3b: Safety re-check pass. Launches in Phase 3 already
            // place windows on the correct workspace via focus-then-launch,
            // so this is only a background safety net for the rare app that
            // ignores the focused workspace. It polls by CLASS (fork-stable)
            // for up to ~15s per target. It MUST run detached: the restore
            // notification fires when the main script exits, and we don't
            // want the notification blocked behind this polling.
            // Exclude pre-existing matched windows via MATCHED_ADDRS
            if (spawnCount > 0) {
                var safety = []
                safety.push("#!/bin/bash")
                safety.push("LOGFILE=\"$WSROOT/restore.log\"")
                // The safety pass is the last consumer of the private WSROOT,
                // so it owns cleanup - removes the whole private dir (only
                // our own files) when it finishes, with a trap for safety.
                // When this restore disabled group:auto_group above, this is
                // also the last thing to run, so it puts the setting back.
                if (hasGroups) {
                    safety.push("trap 'hyprctl keyword group:auto_group \"$ORIG_AUTOGROUP\" >/dev/null 2>&1 || true; rm -rf \"$WSROOT\"' EXIT")
                } else {
                    safety.push("trap 'rm -rf \"$WSROOT\"' EXIT")
                }
                safety.push("MATCHED_ADDRS=\"" + matchedAddrs.join(" ") + "\"")
                safety.push("sleep 1")
                safety.push("MOVED_ADDRS=\"\"")
                for (var s = 0; s < spawnTargets.length; s++) {
                    var t = spawnTargets[s]
                    var jqFilter = '.[] | select((.class | ascii_downcase | gsub("\\\\.desktop$"; "")) == "' + t.cls + '") | [.address, .workspace.name] | @tsv'
                    // Up to ~15s of polling (30 attempts x 0.5s) - electron
                    // apps (Slack, VS Code, Discord) routinely take longer
                    // than a short budget to register their window.
                    safety.push("ATTEMPT=0")
                    safety.push("HANDLED=0")
                    safety.push("while [ $ATTEMPT -lt 30 ] && [ $HANDLED -eq 0 ]; do")
                    safety.push("  MATCHES=$(hyprctl clients -j | jq -r '" + jqFilter + "' 2>>\"$LOGFILE\")")
                    safety.push("  echo \"[move-spawn] attempt=$ATTEMPT cls=" + t.cls + " ws=" + t.ws + " matches=$MATCHES\" >> \"$LOGFILE\"")
                    safety.push("  while IFS=$'\\t' read -r A W; do")
                    safety.push("    [ -z \"$A\" ] && continue")
                    safety.push("    if [[ \" $MOVED_ADDRS \" == *\" $A \"* ]] || [[ \" $MATCHED_ADDRS \" == *\" $A \"* ]]; then continue; fi")
                    safety.push("    MOVED_ADDRS=\"$MOVED_ADDRS $A\"")
                    safety.push("    if [ \"$W\" != \"" + t.ws + "\" ]; then")
                    safety.push("      hyprctl dispatch \"hl.dsp.window.move({workspace='" + t.ws + "', window='address:$A', follow=false})\" 2>>\"$LOGFILE\" || true")
                    if (t.floating) {
                        var sx = root.numOr(t.pos[0])
                        var sy = root.numOr(t.pos[1])
                        var sw = root.numOr(t.size[0])
                        var sh = root.numOr(t.size[1])
                        safety.push("      hyprctl dispatch \"hl.dsp.window.float({action='toggle', window='address:$A'})\" 2>>\"$LOGFILE\" || true")
                        safety.push("      hyprctl dispatch \"hl.dsp.window.move({x=" + sx + ", y=" + sy + ", relative=false, window='address:$A'})\" 2>>\"$LOGFILE\" || true")
                        safety.push("      hyprctl dispatch \"hl.dsp.window.resize({x=" + sw + ", y=" + sh + ", window='address:$A'})\" 2>>\"$LOGFILE\" || true")
                    }
                    if (t.fullscreen) {
                        safety.push("      hyprctl dispatch \"hl.dsp.window.fullscreen({mode='fullscreen', window='address:$A'})\" 2>>\"$LOGFILE\" || true")
                    }
                    safety.push("    fi")
                    // Reform this window's group, if it was part of one (see
                    // Phase 2b2 above) - regardless of whether a workspace
                    // move/reposition happened above, since the window still
                    // needs to be merged either way.
                    if (t.pIndex in groupDirByMember) {
                        var mLines = root.groupMergeLines("$A", groupIdByMemberIdx[t.pIndex], groupDirByMember[t.pIndex], "    ")
                        for (var ml = 0; ml < mLines.length; ml++) safety.push(mLines[ml])
                    }
                    safety.push("    HANDLED=1")
                    safety.push("  done <<< \"$MATCHES\"")
                    safety.push("  ATTEMPT=$((ATTEMPT+1))")
                    safety.push("  if [ $HANDLED -eq 0 ]; then sleep 0.5; fi")
                    safety.push("done")
                }
                // This is the last thing to run when a safety pass exists, so
                // it's the one that puts the original workspace/scratchpad
                // state back.
                var safetyFocusLines = root.restoreOrigFocusLines("")
                for (var sfl = 0; sfl < safetyFocusLines.length; sfl++) safety.push(safetyFocusLines[sfl])
                // Write and detach the safety pass so it doesn't delay the
                // restore notification. The script and everything it uses
                // live in the private $WSROOT (never shared /tmp). Hand
                // cleanup of $WSROOT over to the safety pass, which removes
                // the private dir when it finishes.
                lines.push("SAFETY_OWNED=1")
                lines.push("SAFETY=\"$WSROOT/safety.sh\"")
                lines.push("printf '%s\\n' " + Util.shellQuote(safety.join("\n")) + " > \"$SAFETY\" && chmod 700 \"$SAFETY\"")
                lines.push("nohup bash \"$SAFETY\" >/dev/null 2>&1 &")
                lines.push("disown")
            } else {
                if (hasGroups) {
                    // No safety pass means this script is the last thing to
                    // run - put the setting back here instead.
                    lines.push("hyprctl keyword group:auto_group \"$ORIG_AUTOGROUP\" 2>>\"$LOGFILE\" || true")
                }
                // No safety pass means this script is also the last thing to
                // run, so it's the one that puts the original workspace/
                // scratchpad state back.
                var mainFocusLines = root.restoreOrigFocusLines("")
                for (var mfl = 0; mfl < mainFocusLines.length; mfl++) lines.push(mainFocusLines[mfl])
            }

            var totalCount = toMove.length + toFloat.length + spawnCount

            var scriptContent = lines.join("\n")
            masterRestoreProc._count = totalCount
            // Run everything from a private, freshly-created temp directory
            // (mktemp -d, 0700 with umask 077) instead of predictable shared
            // /tmp pathnames. This avoids symlink/clobber and write/execute
            // races on restore.sh, spawn-*.sh, safety.sh and the log. The
            // restore.sh path is never a replaceable shared name, and the
            // safety pass cleans the private dir up when it finishes.
            masterRestoreProc.command = ["bash", "-c",
                "set -o pipefail; " +
                "WSROOT=$(mktemp -d) || exit 1; " +
                "chmod 700 \"$WSROOT\" || exit 1; " +
                "umask 077; " +
                "export WSROOT; " +
                "printf '%s\\n' " + Util.shellQuote(scriptContent) + " > \"$WSROOT/restore.sh\" && " +
                "bash \"$WSROOT/restore.sh\""]
            masterRestoreProc.running = true
        } catch(err) {
            root.isRestoring = false
            root.lastAction = "Restore failed"
            root.notify("Restore failed", "Could not build restore script")
        }
    }

    // --- Delete ---

    function doDelete(name) {
        var safe = root.sanitizeProfileName(name)
        if (safe === null) {
            root.lastAction = "Invalid profile name"
            return
        }
        delProc.command = ["python3", root.storeScript, "delete", root.profileDir, safe]
        delProc.running = true
    }

    Process {
        id: delProc
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                root.lastAction = "Failed to delete profile"
                root.notify("Failed to delete", "Could not remove profile file")
                return
            }
            root.lastAction = "Deleted"
            root.refreshProfiles()
            root.notify("Profile deleted", "")
        }
    }

    function confirmSave() {
        var name = saveNameField.text.trim()
        if (name.length > 0) {
            root.doSave(name, commentField.text)
        }
    }
}
