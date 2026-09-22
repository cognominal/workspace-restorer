import { test } from "node:test"
import assert from "node:assert/strict"
import {
    sanitizeProfileName,
    validProfilePath,
    shellArg,
    sanitizeLaunchCommand,
    safeWorkspace,
    safeClass,
    numOr,
    profileIconFor,
    generateDefaultName,
    cleanCmd,
    buildMonitorMap,
    browserTypeForClass,
    safeUrl,
    buildTabUrls,
    buildBrowserLaunchCommand,
    buildBrowserLaunchCommands,
    enforceProfileCardinality,
    MAX_WINDOWS,
    MAX_TABS_PER_WINDOW,
    buildGroupMeta,
    buildRestoreGroups,
    mergeDirectionFor,
    groupMergeLines,
    sanitizeComment,
    MAX_COMMENT_LENGTH,
} from "../restoreLogic.mjs"

const DIR = "/home/user/.config/omarchy/workspace-restorer"

// --- sanitizeProfileName ---

test("sanitizeProfileName accepts valid names", () => {
    for (const name of ["coding", "my work", "proj.1", "Media-2", "A", "a1_b2.c3"]) {
        assert.equal(sanitizeProfileName(name), name.trim())
    }
})

test("sanitizeProfileName trims whitespace", () => {
    assert.equal(sanitizeProfileName("  coding  "), "coding")
})

test("sanitizeProfileName rejects non-strings", () => {
    assert.equal(sanitizeProfileName(null), null)
    assert.equal(sanitizeProfileName(undefined), null)
    assert.equal(sanitizeProfileName(123), null)
    assert.equal(sanitizeProfileName({}), null)
})

test("sanitizeProfileName rejects empty / whitespace-only", () => {
    assert.equal(sanitizeProfileName(""), null)
    assert.equal(sanitizeProfileName("   "), null)
})

test("sanitizeProfileName rejects path traversal and separators", () => {
    for (const name of ["..", ".", "../evil", "a/b", "a\\b", "a,b", "a;b"]) {
        assert.equal(sanitizeProfileName(name), null, `should reject: ${name}`)
    }
})

test("sanitizeProfileName rejects hidden files and control chars", () => {
    assert.equal(sanitizeProfileName(".hidden"), null)
    assert.equal(sanitizeProfileName("a\x00b"), null)
    assert.equal(sanitizeProfileName("a\nb"), null)
    assert.equal(sanitizeProfileName("a\tb"), null)
})

test("sanitizeProfileName rejects overly long names", () => {
    assert.equal(sanitizeProfileName("a".repeat(129)), null)
    assert.equal(sanitizeProfileName("a".repeat(128)), "a".repeat(128))
})

test("sanitizeProfileName rejects shell/special metacharacters", () => {
    for (const name of ["x$y", "x`y", "x$(y)", "x|y", "x<y", "x>y", "x&y", "x!y", "x~y", "x%y", "x@y", "x#y", "x?y", "x*y", "x'y", 'x"y']) {
        assert.equal(sanitizeProfileName(name), null, `should reject: ${name}`)
    }
})

// --- validProfilePath ---

test("validProfilePath builds a contained .json path", () => {
    assert.equal(validProfilePath("coding", DIR), DIR + "/coding.json")
})

test("validProfilePath returns null for invalid names", () => {
    assert.equal(validProfilePath("..", DIR), null)
    assert.equal(validProfilePath("../evil", DIR), null)
    assert.equal(validProfilePath("", DIR), null)
    assert.equal(validProfilePath(null, DIR), null)
})

// --- shellArg ---

test("shellArg single-quotes and escapes embedded quotes", () => {
    assert.equal(shellArg("hello"), "'hello'")
    assert.equal(shellArg("it's"), "'it'\\''s'")
    assert.equal(shellArg("$(rm -rf /)"), "'$(rm -rf /)'")
})

test("shellArg handles null/undefined as empty string", () => {
    assert.equal(shellArg(null), "''")
    assert.equal(shellArg(undefined), "''")
})

// --- sanitizeLaunchCommand ---

test("sanitizeLaunchCommand builds safe quoted command", () => {
    assert.equal(sanitizeLaunchCommand("nautilus --new-window"), "'nautilus' '--new-window'")
})

test("sanitizeLaunchCommand accepts ./rel paths and names", () => {
    assert.equal(sanitizeLaunchCommand("./bin/app run"), "'./bin/app' 'run'")
    assert.equal(sanitizeLaunchCommand("app"), "'app'")
})

test("sanitizeLaunchCommand rejects unsafe executables", () => {
    for (const raw of ["$(evil)", "evil$(x)", "evil;ls", "evil|cat", "evil`x`", "evil&", "evil>out", "evil<in", "evil'", "1bad-token!"]) {
        assert.equal(sanitizeLaunchCommand(raw), "", `should reject: ${raw}`)
    }
})

test("sanitizeLaunchCommand accepts multi-arg valid commands", () => {
    assert.equal(sanitizeLaunchCommand("x y"), "'x' 'y'")
})

test("sanitizeLaunchCommand falls back to class when empty", () => {
    assert.equal(sanitizeLaunchCommand("", "Firefox"), "'firefox'")
    assert.equal(sanitizeLaunchCommand(null, "Code"), "'code'")
})

test("sanitizeLaunchCommand returns empty on no input", () => {
    assert.equal(sanitizeLaunchCommand("", ""), "")
    assert.equal(sanitizeLaunchCommand("   ", "   "), "")
})

// --- safeWorkspace ---

test("safeWorkspace accepts plain workspaces", () => {
    assert.equal(safeWorkspace("1"), "1")
    assert.equal(safeWorkspace("my_work2"), "my_work2")
})

test("safeWorkspace accepts Omarchy/Hyprland special workspaces (scratchpad)", () => {
    assert.equal(safeWorkspace("special:scratchpad"), "special:scratchpad")
    assert.equal(safeWorkspace("special:magic"), "special:magic")
})

test("safeWorkspace rejects unsafe/empty/oversized", () => {
    assert.equal(safeWorkspace(""), null)
    assert.equal(safeWorkspace(null), null)
    assert.equal(safeWorkspace("a".repeat(33)), null)
    for (const ws of ["a b", "a;b", "a/b", "$x", "x'y", "a-b", "a.b", "aéb", "special:", "special:a/b", "special:a;b", "other:scratchpad"]) {
        assert.equal(safeWorkspace(ws), null, `should reject: ${ws}`)
    }
})

// --- safeClass ---

test("safeClass accepts plain classes", () => {
    assert.equal(safeClass("firefox"), "firefox")
    assert.equal(safeClass("org.gnome.Nautilus"), "org.gnome.Nautilus")
})

test("safeClass rejects unsafe/oversized", () => {
    assert.equal(safeClass(""), null)
    assert.equal(safeClass(null), null)
    assert.equal(safeClass("a".repeat(129)), null)
    for (const cls of ["a b", "a'b", "a$b", "a(b)", "a;b", "a`b", "a|b", "a*b", "a!b"]) {
        assert.equal(safeClass(cls), null, `should reject: ${cls}`)
    }
})

// --- numOr ---

test("numOr rounds finite numbers", () => {
    assert.equal(numOr("42"), 42)
    assert.equal(numOr(42.7), 43)
    assert.equal(numOr("12.4"), 12)
    assert.equal(numOr(0), 0)
})

test("numOr returns 0 for non-finite", () => {
    assert.equal(numOr("abc"), 0)
    assert.equal(numOr(null), 0)
    assert.equal(numOr(undefined), 0)
    assert.equal(numOr(NaN), 0)
    assert.equal(numOr(Infinity), 0)
})

// --- profileIconFor ---

test("profileIconFor picks keyword-based glyphs", () => {
    assert.equal(profileIconFor("coding"), "\ue796")
    assert.equal(profileIconFor("Work"), "\uf0c0")
    assert.equal(profileIconFor("media"), "\ue602")
    assert.equal(profileIconFor("game"), "\uf11b")
    assert.equal(profileIconFor("terminal"), "\uf120")
})

test("profileIconFor falls back to default", () => {
    assert.equal(profileIconFor("randomxyz"), "\uf2db")
    assert.equal(profileIconFor(""), "\uf2db")
    assert.equal(profileIconFor(null), "\uf2db")
})

// --- generateDefaultName ---

test("generateDefaultName produces snapshot-YYYYMMDD-HHMM", () => {
    const d = new Date(2026, 7, 29, 9, 5) // Aug 29 2026, 09:05
    const name = generateDefaultName(d)
    assert.match(name, /^snapshot-\d{8}-\d{4}$/)
    assert.equal(name, "snapshot-20260829-0905")
})

// --- cleanCmd ---

test("cleanCmd collapses whitespace and trims", () => {
    assert.equal(cleanCmd("  a    b  "), "a b")
    assert.equal(cleanCmd("single  word"), "single word")
})

test("cleanCmd returns null for empty/invalid", () => {
    assert.equal(cleanCmd(""), null)
    assert.equal(cleanCmd("   "), null)
    assert.equal(cleanCmd(null), null)
})

// --- buildMonitorMap ---

test("buildMonitorMap maps monitor id to name", () => {
    const monitors = [{ id: 0, name: "DP-1" }, { id: 1, name: "HDMI-A-1" }]
    assert.deepEqual(buildMonitorMap(monitors), { 0: "DP-1", 1: "HDMI-A-1" })
})

// --- browserTypeForClass ---

test("browserTypeForClass detects Firefox family", () => {
    for (const cls of ["firefox", "Firefox", "librewolf", "floorp", "zen", "tor-browser", "firefox-esr"]) {
        assert.equal(browserTypeForClass(cls), "firefox", `should be firefox: ${cls}`)
    }
})

test("browserTypeForClass detects Chromium family", () => {
    for (const cls of ["google-chrome", "chromium", "brave-browser", "vivaldi", "microsoft-edge", "Google-chrome"]) {
        assert.equal(browserTypeForClass(cls), "chromium", `should be chromium: ${cls}`)
    }
})

test("browserTypeForClass rejects non-browsers", () => {
    for (const cls of ["nautilus", "kitty", "code", "", null, "slack"]) {
        assert.equal(browserTypeForClass(cls), null, `should be null: ${cls}`)
    }
})

// --- safeUrl ---

test("safeUrl accepts http/https URLs", () => {
    assert.equal(safeUrl("https://github.com/foo?q=1#x"), "https://github.com/foo?q=1#x")
    assert.equal(safeUrl("http://example.com/a b"), null) // space rejected
})

test("safeUrl accepts safe special schemes", () => {
    assert.equal(safeUrl("about:blank"), "about:blank")
    assert.equal(safeUrl("about:newtab"), "about:newtab")
    assert.equal(safeUrl("file:///home/user/x"), "file:///home/user/x")
    assert.equal(safeUrl("chrome://settings"), "chrome://settings")
    assert.equal(safeUrl("moz-extension://abc/"), "moz-extension://abc/")
})

test("safeUrl rejects shell metacharacters and garbage", () => {
    for (const url of ["https://x.com/';rm -rf /", "https://x.com/$(x)", "https://x.com/`x`", "https://x.com/a|b", "https://x.com/a&b", "https://x.com/a;b", "https://x.com/a\nb", "not-a-url", "", null, "https://x.com/ x"]) {
        assert.equal(safeUrl(url), null, `should reject: ${url}`)
    }
    assert.equal(safeUrl("ftp://x.com"), "ftp://x.com")
})

// --- buildTabUrls ---

test("buildTabUrls quotes valid URLs and skips blanks", () => {
    const tabs = [
        { url: "https://github.com/" },
        { url: "about:newtab" },
        { url: null },
        { url: "https://x.com/'drop" },
        { url: "https://news.ycombinator.com/" },
    ]
    assert.equal(buildTabUrls(tabs), "'https://github.com/' 'https://news.ycombinator.com/'")
})

test("buildTabUrls returns empty for no usable tabs", () => {
    assert.equal(buildTabUrls([]), "")
    assert.equal(buildTabUrls(null), "")
    assert.equal(buildTabUrls([{ url: "about:newtab" }]), "")
    assert.equal(buildTabUrls([{ url: "https://x.com/;ls" }]), "")
})

// --- buildBrowserLaunchCommand ---

test("buildBrowserLaunchCommand appends --new-window + URLs", () => {
    const tabs = [{ url: "https://github.com/" }, { url: "https://news.ycombinator.com/" }]
    assert.equal(
        buildBrowserLaunchCommand("'firefox'", "firefox", tabs),
        "'firefox' --new-window 'https://github.com/' 'https://news.ycombinator.com/'"
    )
})

test("buildBrowserLaunchCommand falls back to class name when no base command", () => {
    const tabs = [{ url: "https://example.com/" }]
    assert.equal(
        buildBrowserLaunchCommand("", "Google-chrome", tabs),
        "'google-chrome' --new-window 'https://example.com/'"
    )
})

test("buildBrowserLaunchCommand returns base command unchanged when no tabs or non-browser", () => {
    assert.equal(buildBrowserLaunchCommand("'nautilus'", "nautilus", [{ url: "https://x.com" }]), "'nautilus'")
    assert.equal(buildBrowserLaunchCommand("'firefox'", "firefox", []), "'firefox'")
    assert.equal(buildBrowserLaunchCommand("'firefox'", "firefox", null), "'firefox'")
})

test("buildBrowserLaunchCommand strips a stale --new-window tail to avoid duplicate restore", () => {
    // The captured /proc cmdline already carries URLs from a previous restore.
    const polluted = "'/opt/vivaldi/vivaldi-bin' --new-window 'https://github.com/dashboard' 'https://www.reddit.com/'"
    const tabs = [{ url: "https://github.com/dashboard" }, { url: "https://www.reddit.com/" }]
    assert.equal(
        buildBrowserLaunchCommand(polluted, "vivaldi-stable", tabs),
        "'/opt/vivaldi/vivaldi-bin' --new-window 'https://github.com/dashboard' 'https://www.reddit.com/'"
    )
})

// --- enforceProfileCardinality ---

test("enforceProfileCardinality accepts a bounded profile", () => {
    const profile = {
        windows: [
            { class: "kitty", workspace: "1" },
            { class: "firefox", workspace: "2", tabs: [{ url: "https://x.com/" }] },
        ],
    }
    assert.equal(enforceProfileCardinality(profile), profile)
    assert.equal(MAX_WINDOWS, 512)
    assert.equal(MAX_TABS_PER_WINDOW, 300)
})

test("enforceProfileCardinality rejects non-object / missing windows", () => {
    assert.equal(enforceProfileCardinality(null), null)
    assert.equal(enforceProfileCardinality([]), null)
    assert.equal(enforceProfileCardinality("x"), null)
    assert.equal(enforceProfileCardinality({}), null)
    assert.equal(enforceProfileCardinality({ windows: "nope" }), null)
    assert.equal(enforceProfileCardinality({ windows: [null] }), null)
})

test("enforceProfileCardinality rejects too many windows", () => {
    const windows = Array.from({ length: MAX_WINDOWS + 1 }, () => ({ class: "kitty" }))
    assert.equal(enforceProfileCardinality({ windows }), null)
    const ok = Array.from({ length: MAX_WINDOWS }, () => ({ class: "kitty" }))
    assert.equal(enforceProfileCardinality({ windows: ok }) === null, false)
})

test("enforceProfileCardinality rejects tabs beyond the per-window cap", () => {
    const window = Array.from({ length: MAX_TABS_PER_WINDOW }, () => ({ url: "https://x.com/" }))
    assert.equal(enforceProfileCardinality({ windows: [{ tabs: window }] }) === null, false)
    const over = Array.from({ length: MAX_TABS_PER_WINDOW + 1 }, () => ({ url: "https://x.com/" }))
    assert.equal(enforceProfileCardinality({ windows: [{ tabs: over }] }), null)
})

test("enforceProfileCardinality accepts a bounded comment, rejects an oversized one", () => {
    assert.equal(MAX_COMMENT_LENGTH, 4000)
    const windows = [{ class: "kitty" }]
    assert.equal(enforceProfileCardinality({ windows, comment: "x".repeat(MAX_COMMENT_LENGTH) }) === null, false)
    assert.equal(enforceProfileCardinality({ windows, comment: "x".repeat(MAX_COMMENT_LENGTH + 1) }), null)
    // Absent/non-string comment doesn't reject (old profiles predate the field).
    assert.equal(enforceProfileCardinality({ windows }) === null, false)
})

// --- sanitizeComment ---

test("sanitizeComment passes through plain multiline text", () => {
    assert.equal(sanitizeComment("line one\nline two"), "line one\nline two")
    assert.equal(sanitizeComment(""), "")
})

test("sanitizeComment normalizes CRLF and strips control characters, keeping newlines/tabs", () => {
    assert.equal(sanitizeComment("a\r\nb"), "a\nb")
    assert.equal(sanitizeComment("a\nb\tc"), "a\nb\tc")
    assert.equal(sanitizeComment("a\x00\x07\x1fb"), "ab")
})

test("sanitizeComment caps length and tolerates non-string input", () => {
    assert.equal(sanitizeComment("x".repeat(MAX_COMMENT_LENGTH + 50)).length, MAX_COMMENT_LENGTH)
    assert.equal(sanitizeComment(null), "")
    assert.equal(sanitizeComment(undefined), "")
    assert.equal(sanitizeComment(42), "")
})

// --- buildBrowserLaunchCommands ---

test("buildBrowserLaunchCommands passes all URLs without --new-window for Chromium", () => {
    const tabs = [{ url: "https://github.com/" }, { url: "https://www.reddit.com/" }]
    assert.deepEqual(
        buildBrowserLaunchCommands("'google-chrome'", "Google-chrome", tabs),
        ["'google-chrome' 'https://github.com/' 'https://www.reddit.com/'"]
    )
})

test("buildBrowserLaunchCommands keeps a single Chromium tab in one command", () => {
    const tabs = [{ url: "https://github.com/" }]
    assert.deepEqual(
        buildBrowserLaunchCommands("'google-chrome'", "Google-chrome", tabs),
        ["'google-chrome' 'https://github.com/'"]
    )
})

test("buildBrowserLaunchCommands passes all URLs without --new-window for Firefox (no split windows)", () => {
    const tabs = [{ url: "https://github.com/" }, { url: "https://www.reddit.com/" }]
    assert.deepEqual(
        buildBrowserLaunchCommands("'firefox'", "firefox", tabs),
        ["'firefox' 'https://github.com/' 'https://www.reddit.com/'"]
    )
})

test("buildBrowserLaunchCommands returns base command unchanged for non-browsers or no tabs", () => {
    assert.deepEqual(buildBrowserLaunchCommands("'nautilus'", "nautilus", [{ url: "https://x.com" }]), ["'nautilus'"])
    assert.deepEqual(buildBrowserLaunchCommands("'firefox'", "firefox", []), ["'firefox'"])
    assert.deepEqual(buildBrowserLaunchCommands("", "nautilus", [{ url: "https://x.com" }]), [])
})

// --- buildGroupMeta ---

test("buildGroupMeta assigns a shared groupId and per-member groupOrder", () => {
    const clients = [
        { address: "0xA", grouped: ["0xA", "0xB", "0xC"] },
        { address: "0xB", grouped: ["0xA", "0xB", "0xC"] },
        { address: "0xC", grouped: ["0xA", "0xB", "0xC"] },
        { address: "0xD", grouped: [] },
    ]
    const meta = buildGroupMeta(clients)
    assert.equal(meta["0xA"].groupOrder, 0)
    assert.equal(meta["0xB"].groupOrder, 1)
    assert.equal(meta["0xC"].groupOrder, 2)
    assert.equal(meta["0xA"].groupId, meta["0xB"].groupId)
    assert.equal(meta["0xB"].groupId, meta["0xC"].groupId)
    assert.equal(meta["0xD"], undefined)
})

test("buildGroupMeta assigns distinct groupIds to distinct groups", () => {
    const clients = [
        { address: "0xA", grouped: ["0xA", "0xB"] },
        { address: "0xB", grouped: ["0xA", "0xB"] },
        { address: "0xC", grouped: ["0xC", "0xD"] },
        { address: "0xD", grouped: ["0xC", "0xD"] },
    ]
    const meta = buildGroupMeta(clients)
    assert.notEqual(meta["0xA"].groupId, meta["0xC"].groupId)
})

test("buildGroupMeta treats a lone leftover group as ungrouped", () => {
    const clients = [{ address: "0xA", grouped: ["0xA"] }]
    assert.deepEqual(buildGroupMeta(clients), {})
})

test("buildGroupMeta tolerates malformed input", () => {
    assert.deepEqual(buildGroupMeta(null), {})
    assert.deepEqual(buildGroupMeta([null, { address: 5 }, { address: "0xA" }]), {})
})

// --- buildRestoreGroups ---

test("buildRestoreGroups groups by groupId, ordered by groupOrder, refIndex is the lowest order", () => {
    const windows = [
        { class: "kitty", groupId: 1, groupOrder: 2 }, // index 0
        { class: "kitty", groupId: 1, groupOrder: 0 }, // index 1
        { class: "kitty", groupId: 1, groupOrder: 1 }, // index 2
        { class: "firefox" }, // index 3, ungrouped
    ]
    const groups = buildRestoreGroups(windows)
    assert.equal(groups.length, 1)
    assert.equal(groups[0].refIndex, 1)
    assert.deepEqual(groups[0].members, [1, 2, 0])
})

test("buildRestoreGroups drops groups with fewer than 2 members", () => {
    const windows = [{ class: "kitty", groupId: 1, groupOrder: 0 }]
    assert.deepEqual(buildRestoreGroups(windows), [])
})

test("buildRestoreGroups tolerates malformed input", () => {
    assert.deepEqual(buildRestoreGroups(null), [])
    assert.deepEqual(buildRestoreGroups([null, {}]), [])
})

// --- mergeDirectionFor ---

test("mergeDirectionFor points from the member toward the reference window", () => {
    // ref is to the right of member -> look right ("r") from member to find it.
    assert.equal(mergeDirectionFor({ position: [500, 100] }, { position: [100, 100] }), "r")
    assert.equal(mergeDirectionFor({ position: [100, 100] }, { position: [500, 100] }), "l")
    assert.equal(mergeDirectionFor({ position: [100, 500] }, { position: [100, 100] }), "d")
    assert.equal(mergeDirectionFor({ position: [100, 100] }, { position: [100, 500] }), "u")
})

test("mergeDirectionFor defaults to 'r' for co-located or missing positions", () => {
    assert.equal(mergeDirectionFor({ position: [100, 100] }, { position: [100, 100] }), "r")
    assert.equal(mergeDirectionFor({}, {}), "r")
    assert.equal(mergeDirectionFor(null, null), "r")
})

// --- groupMergeLines ---

test("groupMergeLines sets the anchor var when unset, else dispatches a merge", () => {
    const lines = groupMergeLines("0xA", 3, "l", "")
    assert.deepEqual(lines, [
        "if [ -z \"${GRP3_ADDR:-}\" ]; then",
        "  export GRP3_ADDR=\"0xA\"",
        "else",
        "  echo \"[group-merge] gid=3 addr=0xA dir=l\" >> \"$LOGFILE\"",
        "  hyprctl dispatch \"hl.dsp.window.move({window='address:0xA', into_group='l'})\" 2>>\"$LOGFILE\" || true",
        "fi",
    ])
})

test("groupMergeLines accepts a shell variable address expression and indent", () => {
    const lines = groupMergeLines("$A", 0, "r", "    ")
    assert.equal(lines[0], "    if [ -z \"${GRP0_ADDR:-}\" ]; then")
    assert.equal(lines[1], "      export GRP0_ADDR=\"$A\"")
    assert.ok(lines[4].includes("window='address:$A'"))
})
