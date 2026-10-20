import errno
import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("companion", Path(__file__).with_name("msi-screen-kvm.py"))
companion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(companion)


def request(action="status", **fields):
    return {"schemaVersion": 1, "action": action, **fields}


class FixtureTransport:
    def __init__(self, route="upstream", identity=b"00\xa0", version=b"V20", failure=None):
        self.values = {b"00140": identity, b"00150": version, b"008>0": companion.ROUTES[route]}
        self.commands = []
        self.failure = failure
        self.write_attempted = False
        self.write_completed = False

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def query(self, register):
        self.commands.append((b"58" + register, False))
        return self.values[register]

    def send(self, command, mutation=False):
        self.commands.append((command, mutation))
        self.write_attempted = True
        if self.failure:
            raise self.failure
        self.write_completed = True


class CompanionTests(unittest.TestCase):
    def test_real_stdin_boundary_rejects_invalid_input_before_device_access(self):
        executable = Path(__file__).with_name("msi-screen-kvm.py")
        for data in (b"not-json", b" " * 4097):
            process = subprocess.run([sys.executable, str(executable)], input=data,
                                     capture_output=True, timeout=5)
            self.assertEqual(process.returncode, 2)
            response = json.loads(process.stdout)
            self.assertEqual(response["error"]["code"], "invalid_request")
            self.assertFalse(response["writeAttempted"])
            self.assertFalse(response["verified"])

    def run_fixture(self, command, fixture):
        with patch.object(companion.os, "access", return_value=True):
            return companion.execute(command, lambda: (Path("/dev/hidraw-fixture"), Path("/sys/fixture")), lambda _: fixture)

    def test_status_missing_device_never_opens_transport(self):
        opener = Mock(side_effect=AssertionError("must not open"))
        result, code = companion.execute(request(), lambda: None, opener)
        self.assertEqual(code, 0)
        self.assertFalse(result["present"])
        self.assertEqual(result["outcome"], "not_present")
        opener.assert_not_called()

    def test_discovery_matches_usb_ancestors_and_rejects_multiple_controllers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sysfs = root / "class"
            sysfs.mkdir()
            for index, vendor in enumerate(("1462", "046d")):
                usb = root / f"usb{index}"
                hid = usb / "interface" / "hid"
                hid.mkdir(parents=True)
                (usb / "idVendor").write_text(vendor)
                (usb / "idProduct").write_text("3fa4")
                entry = sysfs / f"hidraw{index}"
                entry.mkdir()
                (entry / "device").symlink_to(hid)
            self.assertEqual(companion.discover(sysfs, root / "dev")[0], root / "dev/hidraw0")
            (root / "usb1/idVendor").write_text("1462")
            with self.assertRaises(companion.CompanionError) as caught:
                companion.discover(sysfs, root / "dev")
            self.assertEqual(caught.exception.code, "ambiguous_device")

    def test_request_rejects_ambiguous_or_unbounded_input(self):
        cases = [b'{"schemaVersion":true,"action":"status"}',
                 b'{"schemaVersion":1,"action":"status","target":"usbc"}',
                 b'{"schemaVersion":1,"action":"status","action":"setKVM"}',
                 b'{"schemaVersion":1,"action":"setKVM","expected":"upstream","target":{}}',
                 b" " * 4097]
        for data in cases:
            with self.subTest(data=data[:100]), self.assertRaises(companion.CompanionError):
                companion.parse_request(data)
        self.assertEqual(companion.parse_request(b'{"schemaVersion":1,"action":"status"}'), request())

    def test_identity_stale_state_and_noop_never_send_setting(self):
        fixtures = [
            (FixtureTransport(identity=b"bad"), request("setKVM", expected="upstream", target="usbc"), 2),
            (FixtureTransport(version=b"V19"), request("setKVM", expected="upstream", target="usbc"), 2),
            (FixtureTransport(), request("setKVM", expected="usbc", target="auto"), 2),
            (FixtureTransport(), request("setKVM", expected="upstream", target="upstream"), 0),
        ]
        for fixture, command, expected_code in fixtures:
            result, code = self.run_fixture(command, fixture)
            self.assertEqual(code, expected_code)
            self.assertFalse(result["writeAttempted"])
            self.assertFalse(any(mutation for _, mutation in fixture.commands))
        self.assertEqual(result["outcome"], "unchanged")
        self.assertTrue(result["verified"])

    def test_status_and_one_setter_keep_send_separate_from_verified_route(self):
        fixture = FixtureTransport()
        status, code = self.run_fixture(request(), fixture)
        self.assertEqual(code, 0)
        self.assertEqual(status["state"]["kvm"], "upstream")
        self.assertTrue(status["verified"])
        result, code = self.run_fixture(request("setKVM", expected="upstream", target="usbc"), fixture)
        self.assertEqual(code, 0)
        setters = [command for command, mutation in fixture.commands if mutation]
        self.assertEqual(setters, [b"5b008>0002"])
        self.assertEqual(companion.frame(setters[0]), b"\x015b008>0002\r" + b"\0" * 52)
        self.assertEqual(result["outcome"], "sent")
        self.assertTrue(result["writeCompleted"])
        self.assertFalse(result["acknowledged"])
        self.assertFalse(result["verified"])
        self.assertEqual(result["state"]["kvm"], "upstream", "Response state remains the pre-write observation")

    def test_disconnect_or_short_write_preserves_uncertainty_without_retry(self):
        for failure in [OSError(errno.ENODEV, "gone"), companion.CompanionError("short_write", "incomplete")]:
            fixture = FixtureTransport(failure=failure)
            result, code = self.run_fixture(request("setKVM", expected="upstream", target="usbc"), fixture)
            self.assertEqual(code, 2)
            self.assertEqual(result["outcome"], "unverified")
            self.assertTrue(result["writeAttempted"])
            self.assertFalse(result["writeCompleted"])
            self.assertFalse(result["verified"])
            self.assertEqual(sum(mutation for _, mutation in fixture.commands), 1)

    def test_query_deadline_never_resends_a_timed_out_query(self):
        transport = companion.Hidraw((Path("/dev/fixture"), Path("/sys/fixture")))
        transport.fd = 200
        with patch.object(companion.os, "read", side_effect=BlockingIOError()), \
             patch.object(companion.os, "write", return_value=64) as write, \
             patch.object(companion.select, "select", return_value=([], [], [])) as wait:
            with self.assertRaises(companion.CompanionError) as caught:
                transport.query(b"008>0")
        self.assertEqual(caught.exception.code, "reply_timeout")
        write.assert_called_once_with(200, b"\x0158008>0\r" + b"\0" * 55)
        self.assertGreater(wait.call_args.args[3], 0)
        self.assertLessEqual(wait.call_args.args[3], 3.0)
        self.assertFalse(transport.write_attempted)
        self.assertFalse(transport.write_completed)

    def test_setter_sends_once_without_waiting_for_ack_or_starting_reply_deadline(self):
        transport = companion.Hidraw((Path("/dev/fixture"), Path("/sys/fixture")))
        transport.fd = 200
        with patch.object(companion.os, "read", side_effect=BlockingIOError()), \
             patch.object(companion.os, "write", return_value=64) as write, \
             patch.object(companion.select, "select", side_effect=AssertionError("must not wait for ACK")), \
             patch.object(companion.time, "monotonic", side_effect=AssertionError("must not start reply deadline")):
            transport.send(b"5b008>0002", mutation=True)
        write.assert_called_once_with(200, b"\x015b008>0002\r" + b"\0" * 52)
        self.assertTrue(transport.write_attempted)
        self.assertTrue(transport.write_completed)

    def test_failed_or_short_setter_write_is_attempted_but_never_repeated(self):
        for outcome in (12, OSError(errno.ENODEV, "gone")):
            transport = companion.Hidraw((Path("/dev/fixture"), Path("/sys/fixture")))
            transport.fd = 200
            arguments = {"side_effect": outcome} if isinstance(outcome, Exception) else {"return_value": outcome}
            with patch.object(companion.os, "read", side_effect=BlockingIOError()), \
                 patch.object(companion.os, "write", **arguments) as write, \
                 patch.object(companion.select, "select", side_effect=AssertionError("must not wait for ACK")):
                with self.assertRaises((companion.CompanionError, OSError)):
                    transport.send(b"5b008>0002", mutation=True)
            write.assert_called_once()
            self.assertTrue(transport.write_attempted)
            self.assertFalse(transport.write_completed)

    def test_opened_descriptor_identity_mismatch_sends_no_queries(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            node = root / "hidraw"
            node.touch()
            (root / "dev").write_text("0:0")
            fake_stat = SimpleNamespace(st_mode=stat.S_IFCHR | 0o660, st_rdev=0)
            def wrong_device(_, operation, buffer, mutate):
                buffer[:] = struct.pack("=Ihh", 3, 0x046d, 0xc548 - 0x10000)
                return 0
            transport = companion.Hidraw((node, root))
            with patch.object(companion.os, "fstat", return_value=fake_stat), \
                 patch.object(companion.fcntl, "ioctl", side_effect=wrong_device), \
                 patch.object(transport, "query") as query:
                result, code = companion.execute(request(), lambda: (node, root), lambda _: transport)
            self.assertEqual(code, 2)
            self.assertEqual(result["error"]["code"], "device_changed")
            self.assertFalse(result["writeAttempted"])
            self.assertIsNone(transport.fd)
            query.assert_not_called()

    def test_flock_excludes_second_request_and_close_releases_owned_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            node = root / "hidraw"
            node.touch()
            (root / "dev").write_text("0:0")
            fake_stat = SimpleNamespace(st_mode=stat.S_IFCHR | 0o660, st_rdev=0)
            def raw_info(_, operation, buffer, mutate):
                buffer[:] = struct.pack("=Ihh", 3, 0x1462, 0x3fa4)
                return 0
            with patch.object(companion.os, "fstat", return_value=fake_stat), \
                 patch.object(companion.fcntl, "ioctl", side_effect=raw_info):
                with companion.Hidraw((node, root)):
                    second = companion.Hidraw((node, root))
                    with self.assertRaises(companion.CompanionError) as caught:
                        second.__enter__()
                    self.assertEqual(caught.exception.code, "busy")
                    self.assertIsNone(second.fd)
                with companion.Hidraw((node, root)) as after:
                    self.assertIsNotNone(after.fd)


def usb_fixture(path, vendor, product, device_class="00"):
    path.mkdir(parents=True, exist_ok=True)
    for name, value in (("idVendor", vendor), ("idProduct", product), ("bDeviceClass", device_class)):
        (path / name).write_text(value)
    return path.resolve()


BOLT_DESCRIPTOR = bytes.fromhex(
    "0600ff0901a101851075089506810095069100c0"
    "0600ff0902a101851175089513810095139100c0")


def hid_fixture(class_directory, usb, index, interface="02", descriptor=BOLT_DESCRIPTOR):
    hid = usb / f"{usb.name}:1.{interface}" / f"hid-{index}"
    hid.mkdir(parents=True, exist_ok=True)
    (hid.parent / "bInterfaceNumber").write_text(interface)
    (hid / "report_descriptor").write_bytes(descriptor)
    entry = class_directory / f"hidraw{index}"
    entry.mkdir(parents=True)
    (entry / "device").symlink_to(hid)
    (entry / "dev").write_text("0:0")
    return entry


class PeripheralTests(unittest.TestCase):
    def test_new_actions_accept_only_their_exact_read_requests(self):
        for action in ("layout", "peripherals"):
            self.assertEqual(companion.parse_request(json.dumps(request(action)).encode()), request(action))
            with self.assertRaises(companion.CompanionError):
                companion.parse_request(json.dumps(request(action, target="usbc")).encode())

    def test_layout_reads_exact_eight_registers_without_mutation(self):
        fixture = FixtureTransport()
        fixture.values.update({b"00600": b"002", b"00500": b"003", b"00610": b"002",
                               b"00620": b"002", b"00630": b"001", b"00640": b"003"})
        result, code = companion.execute(request("layout"), lambda: "fixture", lambda _: fixture)
        self.assertEqual(code, 0)
        self.assertEqual(result, {
            "schemaVersion": 1, "action": "layout", "model": "MD342CQP", "protocolVersion": "V20",
            "layout": {"model": "MD342CQP", "protocolVersion": "V20", "mode": "pbp", "source1": "usbc",
                       "source2": "dp", "pipInput": "dp", "pipSize": 1, "pipPosition": 3}})
        self.assertEqual(fixture.commands, [(b"58" + code, False) for code in
                         (b"00140", b"00150", b"00600", b"00500", b"00610", b"00620", b"00630", b"00640")])
        self.assertFalse(fixture.write_attempted)

    def test_layout_rejects_bad_model_encoding_and_out_of_range_values(self):
        for register, invalid in ((b"00140", b"bad"), (b"00600", b"003"), (b"00500", b"004"),
                                  (b"00610", b" 01"), (b"00620", b"01"), (b"00630", b"003"),
                                  (b"00640", b"004"), (b"00640", b"\xff00")):
            fixture = FixtureTransport()
            fixture.values.update({code: b"000" for code in (b"00600", b"00500", b"00610", b"00620", b"00630", b"00640")})
            fixture.values[register] = invalid
            result, code = companion.execute(request("layout"), lambda: "fixture", lambda _: fixture)
            self.assertEqual(code, 2)
            self.assertEqual(result["action"], "layout")
            self.assertNotIn("layout", result)
            self.assertIn(result["error"]["code"], ("invalid_reply", "unsupported_monitor"))
            self.assertFalse(fixture.write_attempted)
        result, code = companion.execute(request("layout"), lambda: None)
        self.assertEqual((code, result["error"]["code"]), (2, "not_present"))

    def test_topology_includes_nested_monitor_hubs_but_excludes_unrelated_and_root_hubs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bus = usb_fixture(root / "usb1", "1d6b", "0002", "09")
            hub = usb_fixture(bus / "1-2", "05e3", "0610", "09")
            msi = usb_fixture(hub / "1-2.1", "1462", "3fa4")
            bolt = usb_fixture(hub / "1-2.2", "046d", "c548")
            nested = usb_fixture(hub / "1-2.3", "05e3", "0610", "09")
            rapoo = usb_fixture(nested / "1-2.3.1", "24ae", "186a")
            listing = root / "devices"
            listing.mkdir()
            for device in (bus, hub, msi, bolt, nested, rapoo):
                (listing / device.name).symlink_to(device)
            found, receivers = companion.peripheral_topology(listing)
            self.assertEqual(found, hub)
            self.assertEqual([r[0]["connection"] for r in receivers], ["monitorHub", "monitorHub"])
            self.assertEqual(receivers[0][1], [bolt])
            other_hub = usb_fixture(bus / "1-4", "05e3", "0610", "09")
            unrelated = usb_fixture(other_hub / "1-4.1", "24ae", "186a")
            other_listing = root / "other-devices"
            other_listing.mkdir()
            for device in (bus, hub, msi, bolt, other_hub, unrelated):
                (other_listing / device.name).symlink_to(device)
            _, other_receivers = companion.peripheral_topology(other_listing)
            self.assertEqual([r[0]["connection"] for r in other_receivers], ["monitorHub", "elsewhere"])
            second = usb_fixture(bus / "1-5", "1462", "3fa4")
            (listing / second.name).symlink_to(second)
            with self.assertRaises(companion.CompanionError) as caught:
                companion.peripheral_topology(listing)
            self.assertEqual(caught.exception.code, "ambiguous_monitor")
            self.assertIsNone(companion.direct_hub(second), "Root hub membership is not monitor attachment")

    def test_endpoint_ignores_keyboard_interfaces_and_deduplicates_vendor_collections(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            usb = usb_fixture(root / "1-2.2", "046d", "c548")
            classes = root / "class"
            hid_fixture(classes, usb, 0, "00")
            hid_fixture(classes, usb, 1, descriptor=BOLT_DESCRIPTOR.replace(b"\x06\x00\xff", b"\x06\x01\x00"))
            first = hid_fixture(classes, usb, 2)
            hid_fixture(classes, usb, 3)
            self.assertEqual(companion.bolt_endpoint(usb, classes, root / "dev"),
                             (root / "dev/hidraw2", first, usb))
            self.assertTrue(companion.bolt_report_descriptor(BOLT_DESCRIPTOR))
            self.assertFalse(companion.bolt_report_descriptor(BOLT_DESCRIPTOR.replace(b"\x95\x13", b"\x95\x12")))
            self.assertFalse(companion.bolt_report_descriptor(BOLT_DESCRIPTOR[:-1]))

    def test_decoder_ignores_unrelated_reports_stale_slots_pages_and_ping_echoes(self):
        pairing = bytes.fromhex("10ff83b5510000")
        response = bytes.fromhex("11ff83b5510234b0000000000000000000000000")
        self.assertEqual(companion.bolt_reply(response, pairing), response[4:])
        self.assertIsNone(companion.bolt_reply(response[:4] + b"\x52" + response[5:], pairing))
        name_request = bytes.fromhex("10ff83b5610100")
        wrong_page = bytes.fromhex("11ff83b561020c4d58204d617374657220335300")
        self.assertIsNone(companion.bolt_reply(wrong_page, name_request))
        ping = bytes.fromhex("1001001b0000a7")
        self.assertEqual(companion.bolt_reply(bytes.fromhex("1001001b0405a7"), ping), b"\x04\x05\xa7")
        self.assertIsNone(companion.bolt_reply(bytes.fromhex("1001001b0405a6"), ping))
        self.assertIsNone(companion.bolt_reply(bytes.fromhex("1002001b0405a7"), ping))
        self.assertIsNone(companion.bolt_reply(bytes.fromhex("01000000000000"), ping))
        with self.assertRaises(companion.CompanionError) as caught:
            companion.bolt_reply(bytes.fromhex("10018f001b0400"), ping)
        self.assertEqual(caught.exception.code, "hidpp_04")

    def test_pairing_queries_preserve_partial_errors_and_never_expose_serials(self):
        class Fixture:
            deadline = float("inf")
            def exchange(self, packet, timeout=0.35):
                if packet[1] == 0xff and packet[4] == 0x51:
                    return bytes.fromhex("510234b012345678") + b"\0" * 8
                if packet[1] == 0xff and packet[4] == 0x61:
                    return b"\x61\x01\x0cMX Master 3S\0"
                if packet[1] == 1:
                    return bytes((4, 5, packet[6]))
                raise companion.CompanionError("reply_timeout", "No metadata reply")
        receiver = {"id": "bolt", "connection": "monitorHub", "pairedDevices": []}
        companion.paired_bolt_devices(Fixture(), receiver)
        self.assertEqual(receiver["pairedDevices"], [{
            "slot": 1, "kind": "mouse", "wirelessProductID": "B034",
            "name": "MX Master 3S", "radio": "responding", "protocolVersion": "4.5"}])
        self.assertIn("Slot 2", receiver["error"])
        self.assertNotIn("12345678", json.dumps(receiver))

    def test_ping_timeout_is_not_responding_but_transport_failure_is_unavailable(self):
        for failure, expected in ((companion.CompanionError("reply_timeout", "Timeout"), "notResponding"),
                                  (companion.CompanionError("hidpp_09", "Resource unavailable"), "notResponding"),
                                  (companion.CompanionError("hidpp_08", "Slot unavailable"), "unavailable"),
                                  (PermissionError(), "unavailable")):
            class Fixture:
                deadline = float("inf")
                def exchange(self, packet, timeout=0.35):
                    if packet[1] != 0xff:
                        raise failure
                    if packet[4] == 0x51:
                        return bytes.fromhex("510134b000000000") + b"\0" * 8
                    if packet[4] == 0x61:
                        return b"\x61\x01\x03Key" + b"\0" * 10
                    raise companion.CompanionError("hidpp_08", "Slot unavailable")
            receiver = {"id": "bolt", "connection": "monitorHub", "pairedDevices": []}
            companion.paired_bolt_devices(Fixture(), receiver)
            self.assertEqual(receiver["pairedDevices"][0]["radio"], expected)
            self.assertNotIn("protocolVersion", receiver["pairedDevices"][0])
            if isinstance(failure, OSError):
                self.assertIn("permission", receiver["error"])

    def test_all_failed_pairing_queries_report_unknown_inventory_not_unpaired(self):
        fixture = SimpleNamespace(deadline=float("inf"), exchange=Mock(
            side_effect=companion.CompanionError("hidpp_03", "Bolt returned HID++ error 0x03")))
        receiver = {"id": "bolt", "connection": "monitorHub", "pairedDevices": []}
        companion.paired_bolt_devices(fixture, receiver)
        self.assertEqual(receiver["pairedDevices"], [])
        self.assertIn("receiver slots may be empty or unavailable", receiver["error"])
        self.assertEqual(fixture.exchange.call_count, 6)

    def test_metadata_or_name_timeout_stops_before_another_ambiguous_receiver_query(self):
        for replies, expected_pairs in (
                ([companion.CompanionError("reply_timeout", "Timeout")], 0),
                ([bytes.fromhex("510234b000000000") + b"\0" * 8,
                  companion.CompanionError("reply_timeout", "Timeout")], 1)):
            fixture = SimpleNamespace(deadline=float("inf"), exchange=Mock(side_effect=replies))
            receiver = {"id": "bolt", "connection": "monitorHub", "pairedDevices": []}
            companion.paired_bolt_devices(fixture, receiver)
            self.assertEqual(fixture.exchange.call_count, len(replies))
            self.assertEqual(len(receiver["pairedDevices"]), expected_pairs)
            self.assertIn("Timeout", receiver["error"])
            if expected_pairs:
                self.assertEqual(receiver["pairedDevices"][0]["radio"], "unavailable")

    def test_zero_protocol_version_does_not_claim_a_responding_device(self):
        def exchange(packet, timeout=0.35):
            if packet[1] == 1:
                return bytes((0, 0, packet[6]))
            if packet[4] == 0x51:
                return bytes.fromhex("510234b000000000") + b"\0" * 8
            if packet[4] == 0x61:
                return b"\x61\x01\x03Key" + b"\0" * 10
            raise companion.CompanionError("hidpp_03", "Slot unavailable")
        receiver = {"id": "bolt", "connection": "monitorHub", "pairedDevices": []}
        companion.paired_bolt_devices(SimpleNamespace(deadline=float("inf"), exchange=exchange), receiver)
        self.assertEqual(receiver["pairedDevices"][0]["radio"], "unavailable")
        self.assertNotIn("protocolVersion", receiver["pairedDevices"][0])
        self.assertIn("invalid protocol", receiver["pairedDevices"][0]["error"])

    def test_elsewhere_receiver_is_not_opened_and_permission_failure_is_explicit(self):
        def topology(connection):
            return lambda: (Path("/hub"), [
                ({"id": "bolt", "connection": connection, "pairedDevices": []}, [Path("/hub/bolt")] if connection == "monitorHub" else []),
                ({"id": "rapoo", "connection": "notDetected", "pairedDevices": []}, [])])
        endpoint = Mock(side_effect=PermissionError())
        snapshot = companion.peripheral_snapshot(topology("elsewhere"), endpoint)
        endpoint.assert_not_called()
        self.assertEqual(snapshot["receivers"][0]["connection"], "elsewhere")
        snapshot = companion.peripheral_snapshot(topology("monitorHub"), endpoint)
        self.assertIn("permission", snapshot["receivers"][0]["error"])
        self.assertEqual(len(snapshot["receivers"]), 2)
        self.assertRegex(snapshot["checkedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")

    def test_exchange_sends_once_and_discards_stale_echo_before_matching_reply(self):
        transport = companion.BoltHidraw((Path("/dev/mock"), Path("/sys/mock"), Path("/usb/mock")), float("inf"))
        transport.fd = 200
        ping = bytes.fromhex("1001001b0000a7")
        reports = [BlockingIOError(), bytes.fromhex("1001001b0405a6"), bytes.fromhex("1001001b0405a7")]
        def ready(reads, writes, errors, timeout):
            return reads, writes, []
        with patch.object(companion.os, "read", side_effect=reports), \
             patch.object(companion.os, "write", return_value=7) as write, \
             patch.object(companion.select, "select", side_effect=ready):
            self.assertEqual(transport.exchange(ping), b"\x04\x05\xa7")
        write.assert_called_once_with(200, ping)
        with patch.object(companion.os, "read", side_effect=BlockingIOError()), \
             patch.object(companion.os, "write", return_value=7) as write, \
             patch.object(companion.select, "select", side_effect=[([], [200], []), ([], [], [])]):
            with self.assertRaises(companion.CompanionError) as caught:
                transport.exchange(ping)
        self.assertEqual(caught.exception.code, "reply_timeout")
        write.assert_called_once_with(200, ping)
        transport.deadline = 0
        with patch.object(companion.os, "write") as write:
            with self.assertRaises(companion.CompanionError) as caught:
                transport.exchange(ping)
        self.assertEqual(caught.exception.code, "session_timeout")
        write.assert_not_called()

    def test_bolt_open_validates_actual_descriptor_identity_and_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            usb = usb_fixture(root / "usb", "046d", "c548")
            entry = hid_fixture(root / "class", usb, 0)
            node = root / "hidraw0"
            node.touch()
            endpoint = (node, entry, usb)
            fake_stat = SimpleNamespace(st_mode=stat.S_IFCHR | 0o660, st_rdev=0)
            def identity(vendor, product):
                def raw_info(_, operation, buffer, mutate):
                    buffer[:] = struct.pack("=Ihh", 3, vendor, product if product < 32768 else product - 65536)
                return raw_info
            with patch.object(companion.os, "fstat", return_value=fake_stat):
                with patch.object(companion.fcntl, "ioctl", side_effect=identity(0x1462, 0x3fa4)):
                    opened = companion.BoltHidraw(endpoint, float("inf"))
                    with self.assertRaises(companion.CompanionError) as caught:
                        opened.__enter__()
                    self.assertEqual(caught.exception.code, "device_changed")
                    self.assertIsNone(opened.fd)
                with patch.object(companion.fcntl, "ioctl", side_effect=identity(0x046d, 0xc548)):
                    with companion.BoltHidraw(endpoint, float("inf")):
                        second = companion.BoltHidraw(endpoint, float("inf"))
                        with self.assertRaises(companion.CompanionError) as caught:
                            second.__enter__()
                        self.assertEqual(caught.exception.code, "busy")
                        self.assertIsNone(second.fd)


class POPFixture:
    """Protocol-shaped replies exercise the same matcher used by the HID endpoint."""
    def __init__(self, features=None, firmware_count=3, control_count=2):
        self.features = features or [0, 1, 3, 0x1004, 0x40a2, 0x1b04]
        self.firmware_count = firmware_count
        self.control_count = control_count
        self.calls = []
        self.failures = {}
        self.kind = 1
        self.product = 0xb35a
        self.name = b"Logi POP Keys"
        self.ping_major = 4
        self.battery = b"\0\x04\0\0"
        self.bad_mapping = False
        self.deadline = float("inf")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def exchange(self, packet, timeout=0.35, ping_echo=True):
        self.calls.append(packet)
        if packet[1] == 0xff:
            if packet[4] == 0x51:
                payload = bytes((0x51, self.kind)) + self.product.to_bytes(2, "little") + bytes.fromhex("deadbeef")
            elif packet[4] == 0x61:
                payload = bytes((0x61, 1, len(self.name))) + self.name
            else:
                raise companion.CompanionError("hidpp_08", "Slot unavailable")
        elif packet[2] == 0 and packet[3] >> 4 == 1:
            payload = bytes((self.ping_major, 5, packet[6]))
        elif packet[2] == 0:
            if packet[4:6] != b"\0\x01":
                raise AssertionError("Only FeatureSet root lookup is permitted")
            payload = b"\x01\0\x01"
        else:
            feature, function = self.features[packet[2]], packet[3] >> 4
            key = (feature, function, packet[4])
            if key in self.failures:
                failure = self.failures[key]
                if isinstance(failure, Exception):
                    raise failure
                report = bytes((0x10, packet[1], 0xff, packet[2], packet[3], failure, 0))
                return companion.bolt_reply(report, packet, ping_echo)
            if feature == 1:
                if function == 0:
                    payload = bytes((len(self.features) - 1,))
                elif function == 1:
                    payload = self.features[packet[4]].to_bytes(2, "big") + b"\0\x01"
                else:
                    raise AssertionError("FeatureSet setter")
            elif feature == 3:
                if function == 0:
                    payload = bytes((self.firmware_count,)) + b"PRIVATE-UNIT-ID"
                elif function == 1:
                    payload = (bytes.fromhex("00504f501234abcd"), bytes.fromhex("01424c4401020003"),
                               bytes.fromhex("0207000000000000"))[packet[4] % 3]
                else:
                    raise AssertionError("Firmware setter")
            elif feature in (0x1000, 0x1001, 0x1004):
                if function != (1 if feature == 0x1004 else 0):
                    raise AssertionError("Battery setter")
                payload = self.battery
            elif feature == 0x40a2:
                if function != 0:
                    raise AssertionError("Fn setter")
                payload = b"\x03\0"
            elif feature == 0x40a0:
                if function != 0:
                    raise AssertionError("Fn setter")
                payload = b"\x01"
            elif feature == 0x1b04:
                if function == 0:
                    payload = bytes((self.control_count,))
                elif function == 1:
                    cid = 0x0104 + packet[4]
                    payload = struct.pack("!HHBBBBB", cid, 0x00d9 + packet[4], 0x18, packet[4] + 1, 1, 2, 1)
                elif function == 2:
                    cid = int.from_bytes(packet[4:6], "big")
                    payload = struct.pack("!HBHB", cid ^ 1 if self.bad_mapping else cid, 1, 0, 1)
                else:
                    raise AssertionError("Control setter")
            else:
                raise AssertionError(f"Unapproved feature getter {feature:04x}")
        report = bytes((0x11, packet[1], packet[2], packet[3])) + payload.ljust(16, b"\0")
        result = companion.bolt_reply(report, packet, ping_echo)
        if result is None:
            raise AssertionError("Fixture reply did not match the request")
        return result


class POPDetailsTests(unittest.TestCase):
    def invoke(self, fixture):
        def open_fixture(_, deadline):
            fixture.deadline = deadline
            return fixture
        return companion.pop_details(
            request("popDetails", slot=1, expectedWirelessProductID="b35a"),
            lambda: (Path("/hub"), [({"id": "bolt"}, [Path("/hub/bolt")])]),
            lambda _: "fixture", open_fixture)

    def test_request_validates_slot_product_and_exact_fields_before_access(self):
        good = request("popDetails", slot=1, expectedWirelessProductID="B35A")
        self.assertEqual(companion.parse_request(json.dumps(good).encode()), good)
        for bad in ({**good, "slot": True}, {**good, "slot": 0}, {**good, "slot": 7},
                    {**good, "expectedWirelessProductID": "ZZZZ"},
                    {**good, "expectedWirelessProductID": "B35A\n"},
                    {**good, "target": "usbc"}):
            with self.assertRaises(companion.CompanionError):
                companion.parse_request(json.dumps(bad).encode())

    def test_details_decode_real_shapes_and_omit_private_identity_fields(self):
        fixture = POPFixture()
        result, code = self.invoke(fixture)
        self.assertEqual(code, 0)
        self.assertEqual(result["name"], "Logi POP Keys")
        self.assertEqual(result["wirelessProductID"], "B35A")
        self.assertTrue(result["featureInventoryComplete"])
        self.assertTrue(result["controlInventoryComplete"])
        self.assertEqual(result["errors"], [])
        self.assertEqual(result["battery"], {"featureID": 0x1004, "level": "good", "statusCode": 0})
        self.assertEqual(result["fnMode"], {"featureID": 0x40a2, "inverted": True, "defaultInverted": False})
        self.assertEqual(result["firmware"][0], {"kind": "firmware", "prefix": "POP", "version": "12.34", "build": 0xabcd})
        self.assertEqual(result["firmware"][2], {"kind": "hardware", "version": "7"})
        self.assertEqual(result["controls"][0], {"controlID": 0x104, "defaultTaskID": 0xd9,
                         "flags": 0x118, "position": 1, "group": 1, "groupMask": 2,
                         "currentControlID": 0x104, "reportingFlags": 0x101})
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertNotIn("deadbeef", json.dumps(result).lower())
        self.assertRegex(result["checkedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertLessEqual(fixture.deadline - companion.time.monotonic(), 8)

    def test_identity_and_radio_revalidation_fail_before_feature_queries(self):
        for property_, value in (("kind", 2), ("product", 0xb35b), ("name", b"Other Keys"), ("ping_major", 1)):
            fixture = POPFixture()
            setattr(fixture, property_, value)
            result, code = self.invoke(fixture)
            self.assertEqual(code, 2)
            self.assertEqual(result["error"]["code"], "device_changed")
            self.assertNotIn("features", result)
            self.assertLessEqual(len(fixture.calls), 3)

    def test_feature_timeout_stops_all_following_queries_without_retries(self):
        fixture = POPFixture()
        fixture.failures[(1, 1, 2)] = companion.CompanionError("reply_timeout", "Fixture timeout")
        result, code = self.invoke(fixture)
        self.assertEqual(code, 0)
        self.assertFalse(result["featureInventoryComplete"])
        self.assertEqual(len(result["features"]), 2)
        self.assertEqual(len(fixture.calls), 8)  # identity3 + lookup/count2 + entries0,1,2
        self.assertEqual(result["firmware"], [])
        self.assertIn("timeout", result["errors"][0].lower())

    def test_explicit_feature_error_allows_other_sections_but_does_not_fake_battery(self):
        fixture = POPFixture()
        fixture.failures[(0x1004, 1, 0)] = 9
        result, code = self.invoke(fixture)
        self.assertEqual(code, 0)
        self.assertNotIn("battery", result)
        self.assertIn("fnMode", result)
        self.assertTrue(result["controlInventoryComplete"])
        self.assertTrue(any("Battery:" in error for error in result["errors"]))

    def test_mapping_echo_mismatch_preserves_capability_without_claiming_mapping(self):
        fixture = POPFixture()
        fixture.bad_mapping = True
        result, code = self.invoke(fixture)
        self.assertEqual(code, 0)
        self.assertEqual(len(result["controls"]), 2)
        self.assertFalse(result["controlInventoryComplete"])
        self.assertNotIn("currentControlID", result["controls"][0])
        self.assertNotIn("reportingFlags", result["controls"][0])
        self.assertTrue(any("echo" in error for error in result["errors"]))

    def test_count_limits_bound_requests_and_mark_partial_inventories(self):
        features = [0, 1, 3, 0x1004, 0x40a2, 0x1b04] + list(range(0x5000, 0x5000 + 64))
        fixture = POPFixture(features, firmware_count=10, control_count=40)
        result, code = self.invoke(fixture)
        self.assertEqual(code, 0)
        self.assertEqual((len(result["features"]), len(result["firmware"]), len(result["controls"])), (64, 8, 32))
        self.assertFalse(result["featureInventoryComplete"])
        self.assertFalse(result["controlInventoryComplete"])
        self.assertEqual(len(fixture.calls), 145)
        self.assertEqual(len(result["errors"]), 3)
        # Exclude the initial pairing/name/ping requests; getters rotate IDs.
        ids = [packet[3] & 15 for packet in fixture.calls[3:]]
        self.assertTrue(all(b == a % 15 + 1 for a, b in zip(ids, ids[1:])))

    def test_unsupported_fn_and_unknown_features_are_capabilities_only(self):
        fixture = POPFixture([0, 1, 0x40a3, 0x1b03, 0xabcd])
        result, code = self.invoke(fixture)
        self.assertEqual(code, 0)
        self.assertEqual(len(result["features"]), 5)
        self.assertNotIn("fnMode", result)
        self.assertEqual(result["controls"], [])
        self.assertTrue(any("current host setting is not read" in error for error in result["errors"]))
        self.assertEqual(len(fixture.calls), 10)

    def test_fixed_getter_allowlist_rejects_setters_and_unadvertised_features(self):
        fixture = POPFixture()
        probe = companion.POPDetailsProbe(fixture, 1, "B35A")
        for feature, operation, parameters in ((0x40a2, 1, b"\1"), (0x1b04, 3, b"\0\1"),
                                                (0x40a3, 0, b"\xff"), (0, 0, b"\x10\x04")):
            with self.assertRaises(companion.CompanionError) as caught:
                probe.get(feature, operation, parameters)
            self.assertEqual(caught.exception.code, "invalid_query")
        with self.assertRaises(companion.CompanionError) as caught:
            probe.get(0x1004, 1)
        self.assertEqual(caught.exception.code, "unsupported_feature")
        self.assertEqual(fixture.calls, [])

    def test_feature_reply_matches_software_id_without_applying_ping_echo_rule(self):
        packet = bytes.fromhex("10010401000000")
        reply = bytes.fromhex("1101040100040300000000000000000000000000")
        self.assertEqual(companion.bolt_reply(reply, packet, ping_echo=False), reply[4:])
        for position, changed in ((1, 2), (2, 5), (3, 2), (3, 0x11)):
            stale = reply[:position] + bytes((changed,)) + reply[position + 1:]
            self.assertIsNone(companion.bolt_reply(stale, packet, ping_echo=False))
        error = bytes.fromhex("1101FF0401090000000000000000000000000000")
        with self.assertRaises(companion.CompanionError) as caught:
            companion.bolt_reply(error, packet, ping_echo=False)
        self.assertEqual(caught.exception.code, "hidpp2_09")
        stale_error = error[:4] + b"\x02" + error[5:]
        self.assertIsNone(companion.bolt_reply(stale_error, packet, ping_echo=False))
        self.assertIsNone(companion.bolt_reply(reply, packet), "Default inventory ping matching stays strict")

    def test_unused_slot_errors_are_suppressed_only_after_valid_pairing_metadata(self):
        for fixture in (POPFixture(), SimpleNamespace(deadline=float("inf"), exchange=Mock(
                side_effect=companion.CompanionError("hidpp_08", "Slot unavailable")))):
            receiver = {"id": "bolt", "connection": "monitorHub", "pairedDevices": []}
            companion.paired_bolt_devices(fixture, receiver)
            if isinstance(fixture, POPFixture):
                self.assertEqual(len(receiver["pairedDevices"]), 1)
                self.assertNotIn("error", receiver)
            else:
                self.assertEqual(receiver["pairedDevices"], [])
                self.assertIn("may be empty or unavailable", receiver["error"])


if __name__ == "__main__":
    unittest.main()
