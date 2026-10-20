import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "tern_shortcut", Path(__file__).with_name("setup_app_switch.py"))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)

OTHER_PATHS = [
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/",
    "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom3/",
]
TERN_SHORTCUT = {
    "name": "Tern",
    "command": "/usr/bin/gtk-launch so.stencil.tern.desktop",
    "binding": "F20",
}


class Settings:
    def __init__(self):
        self.value = {
            "schemaVersion": 1, "action": "tern-status",
            "hostName": "fixture", "user": "fixture", "uid": 1000,
            "shellVersion": "48.2", "customPaths": list(OTHER_PATHS),
            "shortcut": {"name": "", "command": "", "binding": ""},
            "f20Conflicts": [], "ternAvailable": True,
        }
        self.writes = []

    def tern_snapshot(self):
        return copy.deepcopy(self.value)

    def write_tern(self, target):
        self.writes.append(copy.deepcopy(target))
        self.value["customPaths"] = list(target["customPaths"])
        self.value["shortcut"] = dict(target["shortcut"])


class TernShortcutTests(unittest.TestCase):
    def test_pin_preserves_paths_is_idempotent_and_restore_preserves_prior_ownership(self):
        for already_owned in (False, True):
            with self.subTest(already_owned=already_owned):
                backend = Settings()
                if already_owned:
                    backend.value["customPaths"].insert(1, app.TERN_PATH)
                    backend.value["shortcut"] = dict(TERN_SHORTCUT)
                original = backend.tern_snapshot()
                receipt = app.change_tern(backend, "pin-tern", original)
                self.assertTrue(receipt["verified"])
                self.assertEqual(backend.value["shortcut"], TERN_SHORTCUT)
                expected_paths = original["customPaths"] + ([] if already_owned else [app.TERN_PATH])
                self.assertEqual(backend.value["customPaths"], expected_paths)
                self.assertEqual(receipt["target"], {
                    "customPaths": expected_paths, "shortcut": TERN_SHORTCUT})
                repeated = app.change_tern(backend, "pin-tern", backend.tern_snapshot())
                self.assertTrue(repeated["verified"])
                self.assertFalse(repeated["changed"])
                self.assertEqual(len(backend.writes), 0 if already_owned else 1)
                restored = app.change_tern(backend, "restore-tern", receipt)
                self.assertTrue(restored["verified"])
                self.assertEqual(backend.value["customPaths"], original["customPaths"])
                self.assertEqual(backend.value["shortcut"], original["shortcut"])

    def test_pin_refuses_unfamiliar_dedicated_values_conflicts_and_missing_tern(self):
        cases = [
            ("shortcut", {"name": "Someone else's shortcut", "command": "", "binding": ""}),
            ("shortcut", {**TERN_SHORTCUT, "command": "/usr/bin/another-app"}),
            ("f20Conflicts", [OTHER_PATHS[0]]),
            ("ternAvailable", False),
        ]
        for key, value in cases:
            with self.subTest(key=key, value=value):
                backend = Settings()
                backend.value[key] = copy.deepcopy(value)
                original = backend.tern_snapshot()
                with self.assertRaises(ValueError):
                    app.change_tern(backend, "pin-tern", original)
                self.assertEqual(backend.writes, [])
                self.assertEqual(backend.tern_snapshot(), original)

    def test_pin_rechecks_current_host_paths_own_values_and_prerequisites(self):
        changes = [
            ("hostName", "another-host"),
            ("uid", 1001),
            ("customPaths", list(reversed(OTHER_PATHS))),
            ("shortcut", dict(TERN_SHORTCUT)),
            ("f20Conflicts", [OTHER_PATHS[1]]),
            ("ternAvailable", False),
        ]
        for key, value in changes:
            with self.subTest(key=key):
                backend = Settings()
                expected = backend.tern_snapshot()
                backend.value[key] = copy.deepcopy(value)
                current = backend.tern_snapshot()
                with self.assertRaises(ValueError):
                    app.change_tern(backend, "pin-tern", expected)
                self.assertEqual(backend.writes, [])
                self.assertEqual(backend.tern_snapshot(), current)

    def test_restore_requires_owned_after_state_and_valid_fixed_transform(self):
        for key, value in (
            ("hostName", "another-host"),
            ("customPaths", OTHER_PATHS + [app.TERN_PATH,
             "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/new-shortcut/"]),
            ("shortcut", {**TERN_SHORTCUT, "binding": "<Super>F20"}),
        ):
            with self.subTest(stale=key):
                backend = Settings()
                receipt = app.change_tern(backend, "pin-tern", backend.tern_snapshot())
                backend.value[key] = copy.deepcopy(value)
                current = backend.tern_snapshot()
                with self.assertRaises(ValueError):
                    app.change_tern(backend, "restore-tern", receipt)
                self.assertEqual(len(backend.writes), 1)
                self.assertEqual(backend.tern_snapshot(), current)
        for alteration in ("after", "before", "unverified", "dry-run"):
            with self.subTest(receipt=alteration):
                backend = Settings()
                receipt = app.change_tern(backend, "pin-tern", backend.tern_snapshot())
                altered = copy.deepcopy(receipt)
                if alteration == "after":
                    # Match live state to the forged after: the fixed-transform
                    # check, rather than the stale-state check, must reject it.
                    altered["after"]["shortcut"]["command"] = "/usr/bin/another-app"
                    backend.value["shortcut"] = dict(altered["after"]["shortcut"])
                elif alteration == "before":
                    altered["before"]["customPaths"].pop()
                elif alteration == "unverified":
                    altered["verified"] = False
                else:
                    altered["dryRun"] = True
                current = backend.tern_snapshot()
                with self.assertRaises(ValueError):
                    app.change_tern(backend, "restore-tern", altered)
                self.assertEqual(len(backend.writes), 1)
                self.assertEqual(backend.tern_snapshot(), current)

    def test_dry_run_and_failed_readback_do_not_claim_success_or_retry(self):
        backend = Settings()
        planned = app.change_tern(backend, "pin-tern", backend.tern_snapshot(), dry_run=True)
        self.assertTrue(planned["changed"])
        self.assertIsNone(planned["after"])
        self.assertFalse(planned["verified"])
        self.assertEqual(backend.writes, [])

        def partial_write(target):
            backend.writes.append(copy.deepcopy(target))
            backend.value["shortcut"] = dict(target["shortcut"])
            # Simulate the shortcut being staged without its list registration.

        backend.write_tern = partial_write
        failed = app.change_tern(backend, "pin-tern", backend.tern_snapshot())
        self.assertFalse(failed["verified"])
        self.assertIn("error", failed)
        self.assertEqual(len(backend.writes), 1)
        self.assertEqual(failed["after"]["customPaths"], OTHER_PATHS)
        self.assertEqual(failed["after"]["shortcut"], TERN_SHORTCUT)


if __name__ == "__main__":
    unittest.main()
