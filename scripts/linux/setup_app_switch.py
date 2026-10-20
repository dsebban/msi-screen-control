#!/usr/bin/env python3
"""Configure GNOME's native mouse shortcuts without a background process."""

import argparse
import datetime
import json
import os
import platform
import pwd
import shlex
import shutil
import subprocess
import sys

SCHEMA = "org.gnome.desktop.wm.keybindings"
FORWARD = "switch-applications"
BACKWARD = "switch-applications-backward"
KEYS = (FORWARD, BACKWARD)
IDENTITY = ("hostName", "user", "uid", "shellVersion")
MEDIA_SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
CUSTOM_SCHEMA = MEDIA_SCHEMA + ".custom-keybinding"
MEDIA_PATH = "/org/gnome/settings-daemon/plugins/media-keys/"
TERN_PATH = MEDIA_PATH + "custom-keybindings/msi-screen-tern/"
TERN_VALUES = {"name": "Tern", "command": "/usr/bin/gtk-launch so.stencil.tern.desktop", "binding": "F20"}


def bindings(value):
    if not isinstance(value, dict) or set(value) != set(KEYS):
        raise ValueError("Expected exactly the two GNOME application-switcher bindings")
    for shortcuts in value.values():
        if (not isinstance(shortcuts, list) or len(shortcuts) > 128
                or any(not isinstance(item, str) or not 0 < len(item) <= 128 for item in shortcuts)):
            raise ValueError("Invalid GNOME shortcut list")
    return {key: list(value[key]) for key in KEYS}


def configured(value):
    result = bindings(value)
    for key, shortcut in ((FORWARD, "F19"), (BACKWARD, "F18")):
        if shortcut not in result[key]:
            result[key].append(shortcut)
    return result


def validate_snapshot(value):
    if not isinstance(value, dict) or value.get("schemaVersion") != 1 or value.get("action") != "status":
        raise ValueError("Expected a schema 1 status snapshot")
    if (any(not isinstance(value.get(key), str) or not value[key] for key in ("hostName", "user", "shellVersion"))
            or type(value.get("uid")) is not int or value["uid"] <= 0):
        raise ValueError("Invalid GNOME session identity")
    bindings(value.get("bindings"))
    return value


def expected_restore(receipt):
    if (not isinstance(receipt, dict) or receipt.get("schemaVersion") != 1
            or receipt.get("action") != "configure" or receipt.get("verified") is not True
            or receipt.get("dryRun") is not False):
        raise ValueError("Restore requires a verified configure receipt")
    before = validate_snapshot(receipt.get("before"))
    after = validate_snapshot(receipt.get("after"))
    if any(before[key] != after[key] for key in IDENTITY):
        raise ValueError("Configure receipt session identity changed")
    if after["bindings"] != configured(before["bindings"]):
        raise ValueError("Receipt contains changes beyond adding F18/F19")
    return after, bindings(before["bindings"])


def change(backend, action, document, dry_run=False):
    if action == "configure":
        expected = validate_snapshot(document)
        target = configured(expected["bindings"])
    else:
        expected, target = expected_restore(document)
    before = backend.snapshot()
    if (any(before[key] != expected[key] for key in IDENTITY)
            or before["bindings"] != expected["bindings"]):
        raise ValueError("GNOME session or shortcuts changed; read status again before changing them")
    changed = before["bindings"] != target
    receipt = {"schemaVersion": 1, "action": action, "before": before,
               "targetBindings": target, "changed": changed, "dryRun": dry_run,
               "after": None, "verified": False}
    if dry_run:
        return receipt
    if changed:
        backend.write(target)
    after = backend.snapshot()
    receipt["after"] = after
    receipt["verified"] = (all(before[key] == after[key] for key in IDENTITY)
                           and after["bindings"] == target)
    if not receipt["verified"]:
        receipt["error"] = "GNOME shortcut readback differs; no retry or automatic restore was attempted"
    return receipt


def tern_values(snapshot):
    if (not isinstance(snapshot, dict) or snapshot.get("schemaVersion") != 1
            or snapshot.get("action") != "tern-status"):
        raise ValueError("Expected a schema 1 tern-status snapshot")
    if (any(not isinstance(snapshot.get(key), str) or not snapshot[key]
            for key in ("hostName", "user", "shellVersion"))
            or type(snapshot.get("uid")) is not int or snapshot["uid"] <= 0):
        raise ValueError("Invalid GNOME session identity")
    paths, shortcut = snapshot.get("customPaths"), snapshot.get("shortcut")
    if (not isinstance(paths, list) or len(paths) > 128
            or any(not isinstance(path, str) or not path.startswith(MEDIA_PATH + "custom-keybindings/")
                   or not path.endswith("/") or len(path) > 1024 for path in paths)
            or not isinstance(shortcut, dict) or set(shortcut) != set(TERN_VALUES)
            or any(not isinstance(value, str) or len(value) > 4096 for value in shortcut.values())):
        raise ValueError("Invalid GNOME custom shortcut snapshot")
    return {"customPaths": list(paths), "shortcut": dict(shortcut)}


def tern_target(snapshot):
    target = tern_values(snapshot)
    if snapshot.get("ternAvailable") is not True:
        raise ValueError("Tern's desktop application and gtk-launch must already be installed")
    if snapshot.get("f20Conflicts") != []:
        raise ValueError("F20 is assigned to another GNOME shortcut")
    if any(target["shortcut"].values()) and target["shortcut"] != TERN_VALUES:
        raise ValueError("The dedicated Tern shortcut path contains another configuration")
    if TERN_PATH not in target["customPaths"]:
        target["customPaths"].append(TERN_PATH)
    target["shortcut"] = dict(TERN_VALUES)
    return target


def change_tern(backend, action, document, dry_run=False):
    if action == "pin-tern":
        expected = document
        target = tern_target(expected)
    else:
        if (not isinstance(document, dict) or document.get("schemaVersion") != 1
                or document.get("action") != "pin-tern" or document.get("verified") is not True
                or document.get("dryRun") is not False):
            raise ValueError("Restore requires a verified pin-tern receipt")
        original, expected = document.get("before"), document.get("after")
        target = tern_values(original)
        if (tern_values(expected) != tern_target(original)
                or any(original[key] != expected[key] for key in IDENTITY)):
            raise ValueError("Receipt contains changes beyond the dedicated Tern shortcut")
    expected_values = tern_values(expected)
    before = backend.tern_snapshot()
    if (any(before[key] != expected[key] for key in IDENTITY)
            or tern_values(before) != expected_values):
        raise ValueError("GNOME session or custom shortcuts changed; read tern-status again")
    if action == "pin-tern":
        tern_target(before)  # Recheck availability and F20 conflicts immediately before writing.
    receipt = {"schemaVersion": 1, "action": action, "before": before, "target": target,
               "changed": tern_values(before) != target, "dryRun": dry_run,
               "after": None, "verified": False}
    if dry_run:
        return receipt
    if receipt["changed"]:
        backend.write_tern(target)
    after = backend.tern_snapshot()
    receipt["after"] = after
    receipt["verified"] = (all(before[key] == after[key] for key in IDENTITY)
                           and tern_values(after) == target)
    if not receipt["verified"]:
        receipt["error"] = "GNOME Tern shortcut readback differs; no retry or automatic restore was attempted"
    return receipt


class GNOMESettings:
    def __init__(self):
        if platform.system() != "Linux" or os.getuid() == 0:
            raise ValueError("Run as the regular user in their Linux GNOME session")
        try:
            from gi.repository import Gio, GLib
        except ImportError as error:
            raise ValueError("Python GObject bindings are required; no dependencies were installed") from error
        self.gio = Gio
        self.glib = GLib
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        version = bus.call_sync(
            "org.gnome.Shell", "/org/gnome/Shell", "org.freedesktop.DBus.Properties", "Get",
            GLib.Variant("(ss)", ("org.gnome.Shell", "ShellVersion")), GLib.VariantType.new("(v)"),
            Gio.DBusCallFlags.NONE, 5000, None).unpack()[0]
        self.identity = {"hostName": platform.node(), "user": pwd.getpwuid(os.getuid()).pw_name,
                         "uid": os.getuid(), "shellVersion": version}
        self.settings = Gio.Settings.new(SCHEMA)

    def snapshot(self):
        return {"schemaVersion": 1, "action": "status",
                "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                **self.identity,
                "bindings": {key: list(self.settings.get_strv(key)) for key in KEYS}}

    def write(self, target):
        if not all(self.settings.is_writable(key) for key in KEYS):
            raise ValueError("The GNOME application-switcher shortcuts are not writable")
        # Both keys share one delayed GSettings transaction. Never replace
        # unrelated shortcuts, restart the desktop, or run an input listener.
        self.settings.delay()
        try:
            if not all(self.settings.set_strv(key, target[key]) for key in KEYS):
                raise ValueError("GNOME rejected a shortcut change")
            self.settings.apply()
            self.gio.Settings.sync()
        except Exception:
            self.settings.revert()
            raise

    def tern_snapshot(self):
        media = self.gio.Settings.new(MEDIA_SCHEMA)
        custom = self.gio.Settings.new_with_path(CUSTOM_SCHEMA, TERN_PATH)
        paths = list(media.get_strv("custom-keybindings"))
        conflicts = []
        source = self.gio.SettingsSchemaSource.get_default()
        for schema_id in source.list_schemas(True)[0]:
            if not schema_id.startswith(("org.gnome.", "org.freedesktop.")):
                continue
            schema = source.lookup(schema_id, True)
            settings = self.gio.Settings.new(schema_id)
            for key in schema.list_keys():
                kind = schema.get_key(key).get_value_type().dup_string()
                if kind not in ("s", "as"):
                    continue
                value = settings.get_value(key).unpack()
                if (value == "F20" if kind == "s" else "F20" in value):
                    conflicts.append(schema_id + ":" + key)
        for path in paths:
            if path != TERN_PATH:
                other = self.gio.Settings.new_with_path(CUSTOM_SCHEMA, path)
                if other.get_string("binding") == "F20":
                    conflicts.append(path)
        app = self.gio.DesktopAppInfo.new("so.stencil.tern.desktop")
        executable = shlex.split(app.get_executable() or "") if app else []
        available = (len(executable) == 1 and os.path.isfile(executable[0])
                     and os.access(executable[0], os.X_OK) and os.access("/usr/bin/gtk-launch", os.X_OK))
        return {"schemaVersion": 1, "action": "tern-status",
                "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                **self.identity, "customPaths": paths,
                "shortcut": {key: custom.get_string(key) for key in TERN_VALUES},
                "f20Conflicts": sorted(conflicts), "ternAvailable": bool(available)}

    def write_tern(self, target):
        media = self.gio.Settings.new(MEDIA_SCHEMA)
        custom = self.gio.Settings.new_with_path(CUSTOM_SCHEMA, TERN_PATH)
        if (not media.is_writable("custom-keybindings")
                or not all(custom.is_writable(key) for key in TERN_VALUES)):
            raise ValueError("The GNOME custom shortcut settings are not writable")
        dconf = shutil.which("dconf")
        if not dconf:
            raise ValueError("The existing dconf command is required; no dependencies were installed")
        # dconf load changes only these four keys in one transaction across
        # the parent list and dedicated shortcut path. GLib quotes each value.
        payload = "[/]\ncustom-keybindings=" + self.glib.Variant("as", target["customPaths"]).print_(True)
        payload += "\n[custom-keybindings/msi-screen-tern]\n"
        payload += "".join(key + "=" + self.glib.Variant("s", value).print_(True) + "\n"
                           for key, value in target["shortcut"].items())
        result = subprocess.run([dconf, "load", MEDIA_PATH], input=payload, text=True,
                                capture_output=True, timeout=5)
        if result.returncode:
            raise ValueError("GNOME custom shortcut transaction failed: " + result.stderr[:500])
        self.gio.Settings.sync()


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def read_document(path):
    if path == "-":
        raw = sys.stdin.buffer.read(65537)
    else:
        with open(path, "rb") as source:
            raw = source.read(65537)
    if len(raw) > 65536:
        raise ValueError("Snapshot exceeds 64 KiB")
    return json.loads(raw, object_pairs_hook=no_duplicates)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("status")
    commands.add_parser("tern-status")
    configure = commands.add_parser("configure")
    configure.add_argument("--expected", required=True, help="Status JSON path, or - for stdin")
    configure.add_argument("--dry-run", action="store_true")
    restore = commands.add_parser("restore")
    restore.add_argument("--receipt", required=True, help="Verified configure receipt path, or - for stdin")
    restore.add_argument("--dry-run", action="store_true")
    pin = commands.add_parser("pin-tern")
    pin.add_argument("--expected", required=True, help="tern-status JSON path, or - for stdin")
    pin.add_argument("--dry-run", action="store_true")
    unpin = commands.add_parser("restore-tern")
    unpin.add_argument("--receipt", required=True, help="Verified pin-tern receipt path, or - for stdin")
    unpin.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        backend = GNOMESettings()
        if args.action in ("status", "tern-status"):
            result = backend.snapshot() if args.action == "status" else backend.tern_snapshot()
        else:
            document = read_document(args.expected if args.action in ("configure", "pin-tern") else args.receipt)
            operation = change_tern if args.action in ("pin-tern", "restore-tern") else change
            result = operation(backend, args.action, document, args.dry_run)
        print(json.dumps(result, sort_keys=True))
        return 0 if args.action in ("status", "tern-status") or result["dryRun"] or result["verified"] else 1
    except Exception as error:
        print(json.dumps({"schemaVersion": 1, "action": args.action, "error": str(error)[:1000],
                          "verified": False}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
