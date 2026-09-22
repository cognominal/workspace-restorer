import { test } from "node:test"
import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import {
    mkdtempSync,
    chmodSync,
    statSync,
    symlinkSync,
    lstatSync,
    truncateSync,
    rmSync,
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { fileURLToPath } from "node:url"

function mkfifoSync(path) {
    const r = spawnSync("mkfifo", [path])
    assert.equal(r.status, 0, "mkfifo should succeed")
}

const HELPER = fileURLToPath(new URL("../scripts/profile_store.py", import.meta.url))

function hasPython() {
    return spawnSync("python3", ["--version"]).status === 0
}

const valid = JSON.stringify({ windows: [{ class: "org.gnome.Nautilus", workspace: "3" }] })

function run(args, input) {
    return spawnSync("python3", [HELPER, ...args], {
        input,
        encoding: "utf-8",
        timeout: 10000,
    })
}

function tmpStore() {
    const dir = mkdtempSync(join(tmpdir(), "wsrestorer-test-"))
    chmodSync(dir, 0o700)
    return { dir, cleanup: () => rmSync(dir, { recursive: true, force: true }) }
}

// --- init ---

test("init creates a 0700 profile directory", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        const res = run(["init", dir])
        assert.equal(res.status, 0)
        assert.equal(res.stderr, "")
        const st = statSync(dir)
        assert.equal(st.mode & 0o777, 0o700)
    } finally {
        cleanup()
    }
})

// --- save / load / list / delete round trip ---

test("save, list, load, delete round trip", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const saved = run(["save", dir, "my-work"], valid)
        assert.equal(saved.status, 0, saved.stderr)

        const listed = run(["list", dir])
        assert.equal(listed.status, 0)
        assert.deepEqual(JSON.parse(listed.stdout), [{ name: "my-work", comment: "" }])

        const loaded = run(["load", dir, "my-work"])
        assert.equal(loaded.status, 0, loaded.stderr)
        assert.deepEqual(JSON.parse(loaded.stdout), JSON.parse(valid))

        const del = run(["delete", dir, "my-work"])
        assert.equal(del.status, 0, del.stderr)
        assert.deepEqual(JSON.parse(run(["list", dir]).stdout), [])
    } finally {
        cleanup()
    }
})

test("list surfaces each profile's comment", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const withComment = JSON.stringify({
            windows: [{ class: "org.gnome.Nautilus", workspace: "3" }],
            comment: "line one\nline two",
        })
        run(["save", dir, "noted"], withComment)
        run(["save", dir, "bare"], valid) // no comment field at all

        const listed = JSON.parse(run(["list", dir]).stdout)
        const byName = Object.fromEntries(listed.map((e) => [e.name, e.comment]))
        assert.equal(byName["noted"], "line one\nline two")
        assert.equal(byName["bare"], "")
    } finally {
        cleanup()
    }
})

test("save rejects an oversized comment", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const tooLong = JSON.stringify({
            windows: [{ class: "org.gnome.Nautilus" }],
            comment: "x".repeat(4001),
        })
        assert.notEqual(run(["save", dir, "toolong"], tooLong).status, 0)
        const okLen = JSON.stringify({
            windows: [{ class: "org.gnome.Nautilus" }],
            comment: "x".repeat(4000),
        })
        assert.equal(run(["save", dir, "oklen"], okLen).status, 0)
    } finally {
        cleanup()
    }
})

// --- security: symlinks are never followed ---

test("save refuses to follow a planted symlink", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        symlinkSync("/etc/passwd", join(dir, "evil.json"))
        const res = run(["save", dir, "evil"], valid)
        assert.notEqual(res.status, 0)
        assert.equal(lstatSync(join(dir, "evil.json")).isSymbolicLink(), true)
    } finally {
        cleanup()
    }
})

test("load refuses a symlink and delete refuses a symlink", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        symlinkSync("/etc/passwd", join(dir, "evil.json"))
        assert.notEqual(run(["load", dir, "evil"]).status, 0)
        assert.notEqual(run(["delete", dir, "evil"]).status, 0)
        assert.equal(lstatSync(join(dir, "evil.json")).isSymbolicLink(), true)
    } finally {
        cleanup()
    }
})

// --- security: FIFOs never block (O_NONBLOCK + fstat reject) ---

test("load does not block on a FIFO", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        mkfifoSync(join(dir, "pipe.json"))
        const res = run(["load", dir, "pipe"])
        assert.notEqual(res.status, 0) // refused (non-regular), did not hang
    } finally {
        cleanup()
    }
})

// --- security: size and cardinality bounds ---

test("load rejects an oversized profile file", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        run(["save", dir, "big"], valid)
        const bigPath = join(dir, "big.json")
        truncateSync(bigPath, 9 * 1024 * 1024)
        const res = run(["load", dir, "big"])
        assert.notEqual(res.status, 0)
    } finally {
        cleanup()
    }
})

test("save rejects profiles that exceed cardinality bounds", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        const manyWins = JSON.stringify({ windows: Array.from({ length: 600 }, () => ({})) })
        assert.notEqual(run(["save", dir, "many"], manyWins).status, 0)
        const manyTabs = JSON.stringify({ windows: [{ tabs: Array.from({ length: 400 }, () => ({})) }] })
        assert.notEqual(run(["save", dir, "manytabs"], manyTabs).status, 0)
        // An array (not an object) is not a valid profile either.
        assert.notEqual(run(["save", dir, "arr"], JSON.stringify([1, 2, 3])).status, 0)
        // Malformed JSON is rejected.
        assert.notEqual(run(["save", dir, "bad"], "{not json").status, 0)
    } finally {
        cleanup()
    }
})

test("save rejects beyond the 256 profile cap", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        for (let i = 0; i < 256; i++) {
            const r = run(["save", dir, `p${String(i).padStart(3, "0")}`], valid)
            assert.equal(r.status, 0, `save ${i}: ${r.stderr}`)
        }
        const listed = JSON.parse(run(["list", dir]).stdout)
        assert.equal(listed.length, 256)
        // A brand-new name is refused once the cap is reached.
        assert.notEqual(run(["save", dir, "overflow"], valid).status, 0)
        // Overwriting an existing name stays allowed.
        assert.equal(run(["save", dir, "p000"], valid).status, 0)
    } finally {
        cleanup()
    }
})

test("name validation rejects traversal and unsafe names", { skip: !hasPython() }, () => {
    const { dir, cleanup } = tmpStore()
    try {
        run(["init", dir])
        for (const name of ["../escape", ".hidden", "", "has/slash", "$evil", "a b"]) {
            if (name === "") continue
            const res = run(["load", dir, name])
            assert.notEqual(res.status, 0, `should reject name: ${name}`)
        }
        assert.notEqual(run(["save", dir, "../escape"], valid).status, 0)
    } finally {
        cleanup()
    }
})