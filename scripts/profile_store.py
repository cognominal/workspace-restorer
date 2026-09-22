#!/usr/bin/env python3
"""Secure profile store for the Workspace Restorer plugin.

Performs every profile-directory file operation the bar widget needs —
creating the directory, listing profiles, saving, loading, and deleting —
without ever going through a shell and with held-descriptor checks on every
file it touches:

  * paths are opened with O_NOFOLLOW (a symlink is refused, never followed);
  * the opened descriptor is fstat(2)-checked to be a *regular* file owned by
    the current user, so a planted FIFO/device can never block the persistent
    shell or feed/steal data (open uses O_NONBLOCK too, so even a FIFO never
    blocks);
  * reads are bounded (a cap of MAX_PROFILE_BYTES), so an oversized or
    continuous file can never exhaust memory;
  * save validates the JSON and its cardinality (window/tab counts) before
    writing, load revalidates before emitting, and delete is an exact unlink
    of the validated name only (never a glob).

Usage:
  profile_store.py init <dir>
  profile_store.py list <dir>
  profile_store.py save <dir> <name>         # JSON on stdin
  profile_store.py load <dir> <name>         # validated JSON on stdout
  profile_store.py delete <dir> <name>

Failure is reported on stderr with exit code 1.
"""

import json
import os
import re
import stat
import sys

# Cardinality bounds shared with the restore side (see restoreLogic.mjs and
# BarWidget.qml). A loaded profile is command-launch input, so window and tab
# counts are capped before anything is ever generated from it.
MAX_PROFILE_BYTES = 8 * 1024 * 1024
MAX_WINDOWS = 512
MAX_TABS_PER_WINDOW = 300
MAX_PROFILES = 256
MAX_COMMENT_LENGTH = 4000

# Mirrors sanitizeProfileName in restoreLogic.mjs / BarWidget.qml.
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._ \-]{0,127}$")


def _say_error(msg):
    sys.stderr.write("profile_store: %s\n" % msg)


def _check_dir(path):
    """The profile dir must exist and be a real, user-owned directory.

    Uses lstat so a symlinked profile dir is refused rather than followed.
    """
    st = os.lstat(path)
    if not stat.S_ISDIR(st.st_mode):
        raise ValueError("profile dir is not a directory: %s" % path)
    if st.st_uid != os.geteuid():
        raise ValueError("profile dir is not owned by the user: %s" % path)
    return path


def _check_name(name):
    if isinstance(name, str) and _NAME_RE.match(name):
        return name
    raise ValueError("invalid profile name")


def _open_regular(path, flags_extra):
    """Open ``path`` without following symlinks and without ever blocking.

    O_NONBLOCK makes a planted FIFO open return immediately instead of
    blocking the persistent shell; the fstat in ``_require_regular`` then
    rejects it before anything is read or written.
    """
    flags = os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC | flags_extra
    return os.open(path, flags, 0o600)


def _require_regular(fd, path):
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        raise ValueError("not a regular file: %s" % path)
    if st.st_uid != os.geteuid():
        raise ValueError("not owned by the user: %s" % path)
    return st


def _read_bounded(fd, cap):
    data = b""
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        data += chunk
        if len(data) > cap:
            raise ValueError("file exceeds size bound")
    return data


def _read_regular_bounded(path, cap):
    fd = _open_regular(path, os.O_RDONLY)
    try:
        _require_regular(fd, path)
        data = _read_bounded(fd, cap)
    finally:
        os.close(fd)
    return data


def _validate_cardinality(obj):
    if not isinstance(obj, dict):
        raise ValueError("profile must be a JSON object")
    windows = obj.get("windows")
    if not isinstance(windows, list):
        raise ValueError("profile.windows must be an array")
    if len(windows) > MAX_WINDOWS:
        raise ValueError("profile has too many windows (limit %d)" % MAX_WINDOWS)
    for w in windows:
        if not isinstance(w, dict):
            raise ValueError("a profile window must be an object")
        tabs = w.get("tabs")
        if tabs is None:
            continue
        if not isinstance(tabs, list):
            raise ValueError("window tabs must be an array")
        if len(tabs) > MAX_TABS_PER_WINDOW:
            raise ValueError("a window has too many tabs (limit %d)" % MAX_TABS_PER_WINDOW)
    comment = obj.get("comment")
    if comment is not None:
        if not isinstance(comment, str):
            raise ValueError("profile.comment must be a string")
        if len(comment) > MAX_COMMENT_LENGTH:
            raise ValueError("profile.comment too long (limit %d)" % MAX_COMMENT_LENGTH)


def cmd_init():
    dirname = _check_dir_arg()
    os.makedirs(dirname, mode=0o700, exist_ok=True)
    # Re-verify with lstat so a symlink planted between makedirs and here is
    # caught rather than silently accepted.
    _check_dir(dirname)


def _list_profiles(dirname):
    """Return at most ``MAX_PROFILES`` profile names present in ``dirname``.

    Scans via ``os.scandir`` and only accepts regular (non-symlink) ``.json``
    entries whose base name matches the profile-name grammar, so a planted
    symlink or a foreign file can never be listed.
    """
    out = []
    try:
        with os.scandir(dirname) as it:
            for entry in it:
                if len(out) >= MAX_PROFILES:
                    break
                if not entry.name.endswith(".json"):
                    continue
                base = entry.name[:-5]
                if not _NAME_RE.match(base):
                    continue
                try:
                    if entry.is_file(follow_symlinks=False):
                        out.append(base)
                except OSError:
                    continue
    except OSError:
        raise
    out.sort()
    return out


def cmd_list():
    """Emit a JSON array of {"name", "comment"} for every profile.

    The comment is read from each profile file (bounded, no-follow, regular-
    file-only - the same posture as ``cmd_load``) so the UI can show a note
    beside each name without a second round trip per profile. A profile that
    fails to read or parse, or whose comment isn't a plain string, simply
    contributes an empty comment rather than breaking the whole listing.
    """
    dirname = _check_dir_arg()
    _check_dir(dirname)
    names = _list_profiles(dirname)
    out = []
    for name in names:
        comment = ""
        try:
            path = os.path.join(dirname, name + ".json")
            data = _read_regular_bounded(path, MAX_PROFILE_BYTES)
            obj = json.loads(data.decode("utf-8"))
            if isinstance(obj, dict) and isinstance(obj.get("comment"), str):
                comment = obj["comment"][:MAX_COMMENT_LENGTH]
        except Exception:  # noqa: BLE001 - a bad profile just lists with no comment
            comment = ""
        out.append({"name": name, "comment": comment})
    sys.stdout.write(json.dumps(out, ensure_ascii=False))


def cmd_save():
    dirname, name = _check_dir_and_name_args()
    _check_dir(dirname)
    existing = set(_list_profiles(dirname))
    if name not in existing and len(existing) >= MAX_PROFILES:
        raise ValueError("too many profiles (limit %d)" % MAX_PROFILES)
    data = sys.stdin.buffer.read(MAX_PROFILE_BYTES + 1)
    if len(data) > MAX_PROFILE_BYTES:
        raise ValueError("profile too large (limit %d bytes)" % MAX_PROFILE_BYTES)
    try:
        obj = json.loads(data.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 - malformed JSON is rejected wholesale
        raise ValueError("profile is not valid JSON") from exc
    _validate_cardinality(obj)
    payload = json.dumps(obj, indent=2, ensure_ascii=False).encode("utf-8")
    if len(payload) > MAX_PROFILE_BYTES:
        raise ValueError("profile too large after validation")
    path = os.path.join(dirname, name + ".json")
    fd = _open_regular(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    try:
        _require_regular(fd, path)
        os.write(fd, payload)
        os.fsync(fd)
    finally:
        os.close(fd)


def cmd_load():
    dirname, name = _check_dir_and_name_args()
    _check_dir(dirname)
    path = os.path.join(dirname, name + ".json")
    data = _read_regular_bounded(path, MAX_PROFILE_BYTES)
    try:
        obj = json.loads(data.decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise ValueError("profile is not valid JSON") from exc
    _validate_cardinality(obj)
    sys.stdout.write(json.dumps(obj, ensure_ascii=False))


def cmd_delete():
    dirname, name = _check_dir_and_name_args()
    _check_dir(dirname)
    path = os.path.join(dirname, name + ".json")
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(st.st_mode):
        raise ValueError("refusing to delete a symlink")
    if stat.S_ISDIR(st.st_mode):
        raise ValueError("refusing to delete a directory")
    if not stat.S_ISREG(st.st_mode):
        raise ValueError("refusing to delete a non-regular file")
    if st.st_uid != os.geteuid():
        raise ValueError("refusing to delete a file not owned by the user")
    os.unlink(path)


def _check_dir_arg():
    if len(sys.argv) < 3:
        raise ValueError("missing <dir> argument")
    return sys.argv[2]


def _check_dir_and_name_args():
    if len(sys.argv) < 4:
        raise ValueError("missing <dir> and/or <name> arguments")
    return sys.argv[2], _check_name(sys.argv[3])


def main():
    if len(sys.argv) < 2:
        _say_error("usage: profile_store.py <init|list|save|load|delete> <dir> [name]")
        return 1
    op = sys.argv[1]
    try:
        if op == "init":
            cmd_init()
        elif op == "list":
            cmd_list()
        elif op == "save":
            cmd_save()
        elif op == "load":
            cmd_load()
        elif op == "delete":
            cmd_delete()
        else:
            raise ValueError("unknown operation: %s" % op)
    except OSError as exc:
        errno_str = exc.strerror or str(exc)
        _say_error("%s: %s" % (exc.filename or op, errno_str))
        return 1
    except ValueError as exc:
        _say_error(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())