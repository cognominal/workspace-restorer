export function sanitizeProfileName(name) {
    if (typeof name !== "string") return null
    var n = name.trim()
    if (n.length === 0 || n.length > 128) return null
    if (n === "." || n === "..") return null
    if (n.charAt(0) === ".") return null
    if (/[\/\\\x00-\x1f]/.test(n)) return null
    if (!/^[A-Za-z0-9][A-Za-z0-9._ \-]*$/.test(n)) return null
    return n
}

export function validProfilePath(name, profileDir) {
    var safe = sanitizeProfileName(name)
    if (safe === null) return null
    var base = profileDir
    var resolved = base + "/" + safe + ".json"
    if (resolved.indexOf(base) !== 0) return null
    return resolved
}

export function shellArg(s) {
    if (s === null || s === undefined) return "''"
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

export function sanitizeLaunchCommand(raw, fallbackClass) {
    var src = raw || (fallbackClass ? fallbackClass.toLowerCase() : "")
    var tokens = String(src).split(/\s+/).filter(function (t) { return t.length > 0 })
    if (tokens.length === 0) return ""
    if (!/^(\.?\/)?[A-Za-z0-9_][A-Za-z0-9_.+/-]*$/.test(tokens[0])) return ""
    var out = []
    for (var i = 0; i < tokens.length; i++) out.push(shellArg(tokens[i]))
    return out.join(" ")
}

export function safeWorkspace(ws) {
    if (typeof ws !== "string") return null
    // Also accept Hyprland/Omarchy special workspaces (e.g. the scratchpad,
    // reported by hyprctl as "special:scratchpad"), which use a "special:"
    // prefix ahead of the same safe name charset.
    if (!/^(special:)?[_a-z0-9]{1,32}$/i.test(ws)) return null
    return ws
}

export function safeClass(cls) {
    if (typeof cls !== "string") return null
    if (!/^[A-Za-z0-9_.-]{1,128}$/.test(cls)) return null
    return cls
}

export function numOr(v) {
    var n = Number(v)
    return isFinite(n) ? Math.round(n) : 0
}

export function profileIconFor(name) {
    var n = (name || "").toLowerCase()
    if (/code|dev|coding|prog|program|project/.test(n)) return "\ue796"
    if (/work|office|job/.test(n)) return "\uf0c0"
    if (/photo|image|picture|gimp|design|edit|art|draw/.test(n)) return "\uf1c5"
    if (/music|audio|song|media/.test(n)) return "\ue602"
    if (/game|play|gaming/.test(n)) return "\uf11b"
    if (/web|internet|www|browser|search/.test(n)) return "\ue700"
    if (/video|movie|film|stream/.test(n)) return "\uf03d"
    if (/term|shell|cli|console/.test(n)) return "\uf120"
    if (/chat|discord|telegram|message|slack/.test(n)) return "\uf086"
    if (/doc|note|write|text|paper/.test(n)) return "\uf15c"
    if (/file|folder|fm|nautilus|browse/.test(n)) return "\uf07b"
    if (/mail|email|gmail/.test(n)) return "\uf0e0"
    if (/home|default/.test(n)) return "\uf015"
    return "\uf2db"
}

export function generateDefaultName(date) {
    var d = date || new Date()
    var pad = function (n) { return n < 10 ? "0" + n : "" + n }
    return "snapshot-" + d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) +
        "-" + pad(d.getHours()) + pad(d.getMinutes())
}

export function cleanCmd(raw) {
    if (!raw) return null
    var v = raw.replace(/\s+/g, " ").trim()
    return v.length ? v : null
}

export function buildMonitorMap(monitors) {
    var map = {}
    for (var i = 0; i < monitors.length; i++) {
        map[monitors[i].id] = monitors[i].name
    }
    return map
}

// --- Window grouping (tabbed windows) ---
//
// Hyprland reports each grouped (tabbed) window's `grouped` field as the full
// list of member addresses, in tab order, identically on every member. From
// a raw `hyprctl -j clients` array, assign every member a stable groupId
// (shared by all windows in that group, scoped to this one snapshot) and a
// groupOrder (its index in the shared tab order). Windows that aren't
// grouped, or are a lone leftover group of one, get neither.
export function buildGroupMeta(clients) {
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
// .groupOrder, as attached by buildGroupMeta at snapshot time), collect the
// groups that still have 2+ members. For each, pick the lowest-groupOrder
// member as the fixed position reference (`refIndex`, used only for merge-
// direction math - restore may end up resolving members in a different
// order at runtime) and list every member's window index in groupOrder.
export function buildRestoreGroups(windows) {
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
// should carry `memberWin` into a group with `refWin`, based on their
// captured snapshot positions (grouped windows share one tile/rect, so for
// most groups this is a degenerate 0,0 delta and any direction works).
export function mergeDirectionFor(refWin, memberWin) {
    var rx = refWin && Array.isArray(refWin.position) ? numOr(refWin.position[0]) : 0
    var ry = refWin && Array.isArray(refWin.position) ? numOr(refWin.position[1]) : 0
    var mx = memberWin && Array.isArray(memberWin.position) ? numOr(memberWin.position[0]) : 0
    var my = memberWin && Array.isArray(memberWin.position) ? numOr(memberWin.position[1]) : 0
    var dx = rx - mx
    var dy = ry - my
    if (Math.abs(dx) >= Math.abs(dy)) return dx < 0 ? "l" : "r"
    return dy < 0 ? "u" : "d"
}

// Build the restore-script lines that reform one group member into its
// group: the first member to resolve (matched synchronously, or discovered
// later by the Phase 3b safety net) becomes the group's anchor address; every
// later member is merged into it via a directional group-move. `addrExpr` is
// either a literal hyprctl address (matched windows, known at build time) or
// a shell variable reference like "$A" (spawned windows, resolved at
// runtime by the safety net) - both are embedded verbatim into the
// generated bash/dispatch text.
export function groupMergeLines(addrExpr, groupId, dir, indent) {
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

// Cardinality bounds applied to any profile before it is used to generate
// restore commands. A profile is command-launch input, so window and tab
// counts are capped even when it was authored/edited by hand. These mirror
// scripts/profile_store.py so save and load enforce the same limits.
export const MAX_WINDOWS = 512
export const MAX_TABS_PER_WINDOW = 300
export const MAX_COMMENT_LENGTH = 4000

// Validate a parsed profile object's window/tab cardinality. Returns the
// profile unchanged, or null if it is malformed or exceeds the bounds.
export function enforceProfileCardinality(profile) {
    if (!profile || typeof profile !== "object" || Array.isArray(profile)) return null
    if (!Array.isArray(profile.windows)) return null
    if (profile.windows.length > MAX_WINDOWS) return null
    for (var i = 0; i < profile.windows.length; i++) {
        var w = profile.windows[i]
        if (!w || typeof w !== "object" || Array.isArray(w)) return null
        if (!Array.isArray(w.tabs)) continue
        if (w.tabs.length > MAX_TABS_PER_WINDOW) return null
    }
    if (typeof profile.comment === "string" && profile.comment.length > MAX_COMMENT_LENGTH) return null
    return profile
}

// Clean up a user-typed snapshot note before it's stored: normalizes line
// endings, strips control characters (newlines/tabs excepted - it's meant to
// stay multiline), and caps length. Mirrors MAX_COMMENT_LENGTH in
// scripts/profile_store.py. Never null - worst case an empty string, so
// callers can always safely call .length/.split on the result.
export function sanitizeComment(raw) {
    if (typeof raw !== "string") return ""
    var v = raw.replace(/\r\n/g, "\n").replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, "")
    if (v.length > MAX_COMMENT_LENGTH) v = v.slice(0, MAX_COMMENT_LENGTH)
    return v
}

// Class-name sets for browser detection. Matches Firefox-family and
// Chromium-family browsers by their Hyprland window class.
const FIREFOX_CLASSES = /^(firefox|librewolf|waterfox|floorp|tor-browser|zen|palemoon|seamonkey)(\.|-|$)/i
const CHROMIUM_CLASSES = /(chrom|brave|vivaldi|edge|opera|electron)/i

// Return the browser engine type for a window class: "firefox", "chromium",
// or null if it isn't a browser we can tab-capture.
export function browserTypeForClass(cls) {
    if (typeof cls !== "string" || cls.length === 0) return null
    if (FIREFOX_CLASSES.test(cls)) return "firefox"
    if (CHROMIUM_CLASSES.test(cls)) return "chromium"
    return null
}

// Validate a tab URL before it is injected into a launch command. Accepts
// http/https and a conservative set of safe schemes, and rejects anything with
// shell metacharacters or whitespace so a crafted/compromised URL can never
// break out of the generated bash. Returns the trimmed URL or null.
export function safeUrl(url) {
    if (typeof url !== "string") return null
    var u = url.trim()
    if (u.length === 0 || u.length > 4096) return null
    // Scheme + rest; reject any shell metacharacters entirely.
    if (!/^[a-z][a-z0-9+.-]*:\/\/\S+$/i.test(u)) {
        // Allow a few special no-host schemes browsers can show in tabs.
        if (/^(about|chrome|edge|brave|moz-extension|file|view-source|chrome-extension):/i.test(u)) {
            if (/[\s`$;|&<>"'\\\x00-\x1f]/.test(u)) return null
            return u
        }
        return null
    }
    if (/[\s`$;|&<>"'\\\x00-\x1f]/.test(u)) return null
    return u
}

// Build a list of shell-quoted, validated tab URLs (excluding new-tab/blank
// pages that we don't want to reopen) from a snapshot window's tabs array.
// Returns a string like "'url1' 'url2'", or "" if there are no usable tabs.
export function buildTabUrls(tabs) {
    if (!Array.isArray(tabs)) return ""
    var out = []
    for (var i = 0; i < tabs.length; i++) {
        var tab = tabs[i]
        if (!tab || typeof tab.url !== "string") continue
        var url = safeUrl(tab.url)
        if (url === null) continue
        var lower = url.toLowerCase()
        if (lower === "about:newtab" || lower === "about:blank" || lower === "") continue
        out.push(shellArg(url))
    }
    return out.join(" ")
}

// Given a base launch command string and a browser window snapshot, append the
// tab URLs with --new-window when tabs are present. Returns the augmented
// command ("" if nothing usable). Used by restore to reopen a browser's pages.
export function buildBrowserLaunchCommand(pureCommand, cls, tabs) {
    var cmd = pureCommand || ""
    var type = browserTypeForClass(cls)
    if (!type) return cmd
    var urls = buildTabUrls(tabs)
    if (urls.length === 0) return cmd
    // If the base command is empty, fall back to the browser executable name.
    var base = cmd.length > 0 ? cmd : "'" + cls.toLowerCase() + "'"
    // Strip a stale `--new-window <urls>` tail left over from a previous
    // restore (the captured /proc cmdline still carries it), otherwise we'd
    // append another URL list and reopen duplicates.
    var marker = base.indexOf(" --new-window ")
    if (marker !== -1) base = base.slice(0, marker)
    return base + " --new-window " + urls
}

// Like buildBrowserLaunchCommand but returns an array of shell commands to run
// in sequence (one launch step per element), which the restore script executes
// line by line.  When the browser is already running (the common case), passing
// `--new-window url1 url2` to Firefox opens ONE window per URL, and Vivaldi's
// own session restore may add extra tabs.  To avoid both problems we pass all
// URLs without `--new-window` so they open as tabs in the existing window
// (single window, all tabs, no duplicates).  When the browser is not running,
// the same command opens one fresh window with all tabs.
export function buildBrowserLaunchCommands(pureCommand, cls, tabs) {
    var cmd = pureCommand || ""
    var type = browserTypeForClass(cls)
    if (!type) return cmd ? [cmd] : []
    var urls = buildTabUrls(tabs)
    if (urls.length === 0) return cmd ? [cmd] : []
    var base = cmd.length > 0 ? cmd : "'" + cls.toLowerCase() + "'"
    var marker = base.indexOf(" --new-window ")
    if (marker !== -1) base = base.slice(0, marker)
    return [base + " " + urls]
}

