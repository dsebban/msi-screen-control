import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("app_switch", Path(__file__).with_name("setup_app_switch.py"))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)


class Settings:
    def __init__(self):
        self.value = {"schemaVersion": 1, "action": "status", "hostName": "fixture", "user": "fixture",
                      "uid": 1000, "shellVersion": "48.2",
                      "bindings": {app.FORWARD: ["<Super>Tab", "<Alt>Tab"],
                                   app.BACKWARD: ["<Shift><Super>Tab", "<Shift><Alt>Tab"]}}
        self.writes = []

    def snapshot(self):
        return copy.deepcopy(self.value)

    def write(self, target):
        self.writes.append(copy.deepcopy(target))
        self.value["bindings"] = copy.deepcopy(target)


class AppSwitchTests(unittest.TestCase):
    def test_configure_preserves_shortcuts_is_idempotent_and_restores_exactly(self):
        backend = Settings()
        before = backend.snapshot()
        receipt = app.change(backend, "configure", before)
        self.assertTrue(receipt["verified"])
        self.assertEqual(backend.value["bindings"][app.FORWARD], ["<Super>Tab", "<Alt>Tab", "F19"])
        self.assertEqual(backend.value["bindings"][app.BACKWARD],
                         ["<Shift><Super>Tab", "<Shift><Alt>Tab", "F18"])
        repeated = app.change(backend, "configure", backend.snapshot())
        self.assertFalse(repeated["changed"])
        self.assertEqual(len(backend.writes), 1)
        restored = app.change(backend, "restore", receipt)
        self.assertTrue(restored["verified"])
        self.assertEqual(backend.value["bindings"], before["bindings"])

    def test_stale_or_different_host_configuration_does_not_write(self):
        for key, value in (("hostName", "another-host"), ("uid", 1001)):
            backend = Settings()
            expected = backend.snapshot()
            expected[key] = value
            with self.assertRaisesRegex(ValueError, "changed"):
                app.change(backend, "configure", expected)
            self.assertEqual(backend.writes, [])
        backend = Settings()
        expected = backend.snapshot()
        backend.value["bindings"][app.FORWARD].append("<Control>Tab")
        with self.assertRaisesRegex(ValueError, "changed"):
            app.change(backend, "configure", expected)
        self.assertEqual(backend.writes, [])

    def test_restore_refuses_newer_shortcuts_and_tampered_receipt(self):
        backend = Settings()
        receipt = app.change(backend, "configure", backend.snapshot())
        backend.value["bindings"][app.FORWARD].append("<Control>Tab")
        with self.assertRaisesRegex(ValueError, "changed"):
            app.change(backend, "restore", receipt)
        self.assertEqual(len(backend.writes), 1)
        altered = copy.deepcopy(receipt)
        altered["before"]["bindings"][app.FORWARD] = ["<Control>Tab"]
        with self.assertRaisesRegex(ValueError, "beyond"):
            app.change(backend, "restore", altered)
        self.assertEqual(len(backend.writes), 1)

    def test_dry_run_does_not_mutate_and_mismatched_readback_is_not_verified(self):
        backend = Settings()
        planned = app.change(backend, "configure", backend.snapshot(), dry_run=True)
        self.assertIsNone(planned["after"])
        self.assertFalse(planned["verified"])
        self.assertEqual(backend.writes, [])
        backend.write = lambda target: None
        failed = app.change(backend, "configure", backend.snapshot())
        self.assertFalse(failed["verified"])
        self.assertIn("error", failed)
        self.assertEqual(failed["before"]["bindings"], failed["after"]["bindings"])

    def test_preexisting_wheel_binding_is_retained_by_restore(self):
        backend = Settings()
        backend.value["bindings"][app.FORWARD].append("F19")
        original = backend.snapshot()
        receipt = app.change(backend, "configure", original)
        app.change(backend, "restore", receipt)
        self.assertEqual(backend.value["bindings"], original["bindings"])


if __name__ == "__main__":
    unittest.main()
