#!/usr/bin/env python3
"""One-shot MD342CQP/V20 USB KVM control. Standard library only; no daemon."""
import errno
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import select
import stat
import struct
import sys
import time

SCHEMA_VERSION = 1
MAX_REQUEST = 4096
REPLY_TIMEOUT = 3.0
ROUTES = {"auto": b"000", "upstream": b"001", "usbc": b"002"}
KVM_REGISTER = b"008>0"
# Linux HIDIOCGRAWINFO: _IOR('H', 0x03, struct hidraw_devinfo), 8 bytes.
HIDIOCGRAWINFO = 0x80084803


class CompanionError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def frame(command):
    payload = b"\x01" + command + b"\r"
    return payload.ljust(64, b"\0")


def body(report):
    if not report or len(report) > 64:
        raise CompanionError("invalid_reply", "Invalid HID report length")
    if report[0] == 1:
        report = report[1:]
    if b"\r" not in report:
        raise CompanionError("invalid_reply", "Unterminated HID reply")
    return report.split(b"\r", 1)[0]


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CompanionError("invalid_request", "Duplicate JSON request field")
        result[key] = value
    return result


def parse_request(data):
    if len(data) > MAX_REQUEST:
        raise CompanionError("invalid_request", "Request exceeds 4096 bytes")
    try:
        request = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, ValueError) as error:
        raise CompanionError("invalid_request", "Expected one UTF-8 JSON request") from error
    if not isinstance(request, dict) or type(request.get("schemaVersion")) is not int or request["schemaVersion"] != 1:
        raise CompanionError("invalid_request", "Expected schemaVersion 1")
    action = request.get("action")
    fields = {"schemaVersion", "action"} if action in ("status", "peripherals", "layout") else {"schemaVersion", "action", "expected", "target"}
    if action == "popDetails":
        fields = {"schemaVersion", "action", "slot", "expectedWirelessProductID"}
    if action not in ("status", "setKVM", "peripherals", "layout", "popDetails") or set(request) != fields:
        raise CompanionError("invalid_request", "Unknown action or unexpected request fields")
    if action == "setKVM" and any(type(request[key]) is not str or request[key] not in ROUTES for key in ("expected", "target")):
        raise CompanionError("invalid_request", "KVM routes are auto, upstream or usbc")
    if action == "popDetails":
        product = request["expectedWirelessProductID"]
        if (type(request["slot"]) is not int or not 1 <= request["slot"] <= 6
                or type(product) is not str or len(product) != 4
                or any(character not in "0123456789abcdefABCDEF" for character in product)):
            raise CompanionError("invalid_request", "POP details require slot 1 through 6 and a four-digit hexadecimal product ID")
    return request


def read_request(descriptor=0):
    deadline = time.monotonic() + REPLY_TIMEOUT
    chunks = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([descriptor], [], [], remaining)[0]:
            raise CompanionError("invalid_request", "JSON stdin did not finish within 3 seconds")
        chunk = os.read(descriptor, min(1024, MAX_REQUEST + 1 - len(chunks)))
        if not chunk:
            return parse_request(bytes(chunks))
        chunks.extend(chunk)
        if len(chunks) > MAX_REQUEST:
            raise CompanionError("invalid_request", "Request exceeds 4096 bytes")


def discover(sysfs=Path("/sys/class/hidraw"), device_directory=Path("/dev")):
    matches = []
    for entry in sorted(sysfs.glob("hidraw*")):
        device = (entry / "device").resolve()
        for ancestor in (device, *device.parents):
            try:
                vendor = (ancestor / "idVendor").read_text().strip().lower()
                product = (ancestor / "idProduct").read_text().strip().lower()
            except (OSError, UnicodeError):
                continue
            if vendor == "1462" and product == "3fa4":
                matches.append((device_directory / entry.name, entry))
            break
    if len(matches) > 1:
        raise CompanionError("ambiguous_device", "More than one MSI controller is present")
    return matches[0] if matches else None


class Hidraw:
    def __init__(self, device):
        self.path, self.sysfs = device
        self.fd = None
        self.write_attempted = False
        self.write_completed = False

    def __enter__(self):
        try:
            self.fd = os.open(self.path, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
            info = os.fstat(self.fd)
            expected = (self.sysfs / "dev").read_text().strip()
            if not stat.S_ISCHR(info.st_mode) or expected != f"{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}":
                raise CompanionError("device_changed", "MSI device changed before opening; read status again")
            # Check the opened descriptor as well: a hotplug can reuse the
            # sysfs path and major/minor before open completes.
            raw_info = bytearray(8)
            fcntl.ioctl(self.fd, HIDIOCGRAWINFO, raw_info, True)
            bus, vendor, product = struct.unpack("=Ihh", raw_info)
            if (bus, vendor & 0xffff, product & 0xffff) != (0x03, 0x1462, 0x3fa4):
                raise CompanionError("device_changed", "Opened HID device is not the MSI controller; no report sent")
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self
        except BlockingIOError as error:
            self.close()
            raise CompanionError("busy", "Another companion request owns this MSI controller") from error
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def __exit__(self, *_):
        self.close()

    def drain(self):
        # Discard queued input before assigning the next report to a request.
        # Bound this work so a noisy endpoint cannot postpone the deadline.
        for _ in range(32):
            try:
                report = os.read(self.fd, 65)
            except BlockingIOError:
                return
            if not report:
                raise CompanionError("disconnected", "MSI USB controller disconnected")
        raise CompanionError("noisy_device", "Unexpected queued HID input; no request sent")

    def send(self, command, mutation=False):
        self.drain()
        packet = frame(command)
        if mutation:
            # Any error after this point leaves the setting outcome uncertain.
            self.write_attempted = True
        count = os.write(self.fd, packet)
        if count != len(packet):
            raise CompanionError("short_write", "Incomplete HID write; do not repeat the change automatically")
        if mutation:
            self.write_completed = True

    def exchange(self, command):
        self.send(command)
        deadline = time.monotonic() + REPLY_TIMEOUT
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise CompanionError("reply_timeout", "No HID reply within 3 seconds; read status before another change")
            try:
                report = os.read(self.fd, 65)
            except BlockingIOError:
                continue
            if not report:
                raise CompanionError("disconnected", "MSI USB controller disconnected")
            return body(report)

    def query(self, register):
        reply = self.exchange(b"58" + register)
        prefix = b"5b" + register
        if not reply.startswith(prefix) or len(reply) <= len(prefix):
            raise CompanionError("invalid_reply", "HID reply does not match the requested register")
        return reply[len(prefix):]


def read_state(transport):
    if transport.query(b"00140") != b"00\xa0" or transport.query(b"00150") != b"V20":
        raise CompanionError("unsupported_monitor", "Expected MSI MD342CQP / V20; no setting changed")
    value = transport.query(KVM_REGISTER)
    for route, encoded in ROUTES.items():
        if value == encoded:
            return {"model": "MD342CQP", "protocolVersion": "V20", "kvm": route}
    raise CompanionError("invalid_reply", "Unrecognized KVM route")


def layout_snapshot(find_device, transport_type):
    result = {"schemaVersion": 1, "action": "layout"}
    try:
        device = find_device()
        if device is None:
            raise CompanionError("not_present", "MSI USB controller is not connected to this computer")
        with transport_type(device) as transport:
            model = transport.query(b"00140")
            version = transport.query(b"00150")
            if model != b"00\xa0" or version != b"V20":
                raise CompanionError("unsupported_monitor", "Expected MSI MD342CQP / V20")
            layout = {"model": "MD342CQP", "protocolVersion": "V20"}
            fields = (("mode", b"00600", ("off", "pip", "pbp")),
                      ("source1", b"00500", ("hdmi1", "hdmi2", "dp", "usbc")),
                      ("source2", b"00610", ("hdmi1", "hdmi2", "dp", "usbc")),
                      ("pipInput", b"00620", ("hdmi1", "hdmi2", "dp", "usbc")),
                      ("pipSize", b"00630", (0, 1, 2)),
                      ("pipPosition", b"00640", (0, 1, 2, 3)))
            for name, register, values in fields:
                encoded = transport.query(register)
                if len(encoded) != 3 or any(byte < 48 or byte > 57 for byte in encoded) or int(encoded) >= len(values):
                    raise CompanionError("invalid_reply", f"Unsupported layout value for {name}")
                layout[name] = values[int(encoded)]
            result.update(model="MD342CQP", protocolVersion="V20", layout=layout)
            return result, 0
    except (CompanionError, OSError) as error:
        result["error"] = error_details(error)
        return result, 2


def error_details(error):
    if isinstance(error, CompanionError):
        return {"code": error.code, "message": str(error)}
    if isinstance(error, PermissionError):
        return {"code": "permission_denied", "message": "MSI hidraw needs read/write permission for this user"}
    if isinstance(error, OSError) and error.errno in (errno.ENODEV, errno.ENXIO, errno.EIO):
        return {"code": "disconnected", "message": "MSI USB controller disconnected"}
    return {"code": "io_error", "message": "Could not access the MSI USB controller"}


def usb_identity(device):
    try:
        return ((device / "idVendor").read_text().strip().lower(),
                (device / "idProduct").read_text().strip().lower())
    except (OSError, UnicodeError):
        return None


def usb_ancestor(device):
    return next((parent for parent in (device, *device.parents) if usb_identity(parent)), None)


def direct_hub(device):
    parent = device.parent
    try:
        # A host's root hub does not establish that two devices share the
        # monitor's hub. Require a downstream hub, directly above the device.
        if (parent / "bDeviceClass").read_text().strip().lower() == "09" and usb_identity(parent.parent):
            return parent
    except (OSError, UnicodeError):
        pass
    return None


def below_hub(device, hub):
    parent, visited = device.parent, set()
    for _ in range(32):
        if parent == hub:
            return True
        if parent in visited:
            break
        visited.add(parent)
        parent = parent.parent
    return False


def peripheral_topology(usbfs=Path("/sys/bus/usb/devices")):
    devices = {}
    for entry in sorted(usbfs.glob("*")):
        device = entry.resolve()
        identity = usb_identity(device)
        if identity:
            devices[device] = identity
    controllers = [path for path, identity in devices.items() if identity == ("1462", "3fa4")]
    if len(controllers) > 1:
        raise CompanionError("ambiguous_monitor", "More than one MSI controller is present; monitor hub ownership is unknown")
    hub = direct_hub(controllers[0]) if len(controllers) == 1 else None
    receivers = []
    for identifier, identity in (("bolt", ("046d", "c548")), ("rapoo", ("24ae", "186a"))):
        matches = [path for path, value in devices.items() if value == identity]
        attached = [path for path in matches if hub is not None and below_hub(path, hub)]
        connection = "monitorHub" if attached else "elsewhere" if matches else "notDetected"
        receivers.append(({"id": identifier, "connection": connection, "pairedDevices": []}, attached))
    return hub, receivers


def bolt_report_descriptor(data):
    """Require vendor HID++ input reports and short output, excluding key interfaces."""
    if not data or len(data) > 16384:
        return False
    globals_ = {"page": 0, "size": 0, "count": 0, "id": 0}
    stack, collections, bits, vendor_bits = [], [], {}, {}
    offset = 0
    while offset < len(data):
        prefix = data[offset]
        offset += 1
        if prefix == 0xfe:  # Unneeded long items are not accepted by this narrow decoder.
            return False
        size = (0, 1, 2, 4)[prefix & 3]
        if offset + size > len(data):
            return False
        value = int.from_bytes(data[offset:offset + size], "little")
        offset += size
        kind, tag = (prefix >> 2) & 3, prefix >> 4
        if kind == 1:
            key = {0: "page", 7: "size", 8: "id", 9: "count"}.get(tag)
            if key:
                globals_[key] = value
            elif tag == 10:
                stack.append(globals_.copy())
            elif tag == 11:
                if not stack:
                    return False
                globals_ = stack.pop()
        elif kind == 0:
            if tag == 10:
                collections.append(globals_["page"] == 0xff00 or any(collections))
            elif tag == 12:
                if not collections:
                    return False
                collections.pop()
            elif tag in (8, 9):
                key = (tag, globals_["id"])
                count = globals_["size"] * globals_["count"]
                if count > 16384:
                    return False
                bits[key] = bits.get(key, 0) + count
                if globals_["page"] == 0xff00 or any(collections):
                    vendor_bits[key] = vendor_bits.get(key, 0) + count
    required = {(8, 0x10): 48, (8, 0x11): 152, (9, 0x10): 48}
    return not collections and not stack and all(bits.get(key) == count == vendor_bits.get(key) for key, count in required.items())


def bolt_endpoint(usb, hidraw=Path("/sys/class/hidraw"), device_directory=Path("/dev")):
    candidates = []
    for entry in sorted(hidraw.glob("hidraw*")):
        device = (entry / "device").resolve()
        if usb_ancestor(device) != usb:
            continue
        interface = next((parent for parent in (device, *device.parents) if (parent / "bInterfaceNumber").is_file()), None)
        try:
            if interface is None or (interface / "bInterfaceNumber").read_text().strip() != "02":
                continue
            with (device / "report_descriptor").open("rb") as source:
                descriptor = source.read(16385)
            if bolt_report_descriptor(descriptor):
                candidates.append((device_directory / entry.name, entry, usb))
        except (OSError, UnicodeError):
            continue
    # Multiple collections can describe the same physical receiver. Query one
    # verified vendor endpoint, never each duplicate or a keyboard interface.
    if not candidates:
        raise CompanionError("missing_endpoint", "Could not identify Bolt's vendor HID++ interface 02")
    return candidates[0]


def bolt_reply(report, request, ping_echo=True):
    """Return only the requested protocol payload; ignore unrelated input."""
    if not ((len(report) == 7 and report[0] == 0x10) or (len(report) == 20 and report[0] == 0x11)):
        return None
    if report[1] != request[1]:
        return None
    if report[0] == 0x10 and report[2] == 0x8f and report[3:5] == request[2:4]:
        raise CompanionError(f"hidpp_{report[5]:02x}", f"Bolt returned HID++ error 0x{report[5]:02X}")
    if report[2] == 0xff and report[3:5] == request[2:4]:
        raise CompanionError(f"hidpp2_{report[5]:02x}", f"Device returned HID++ error 0x{report[5]:02X}")
    if report[2:4] != request[2:4]:
        return None
    if request[2:4] == b"\x83\xb5":
        if len(report) != 20 or report[4] != request[4]:
            return None
        if 0x61 <= request[4] <= 0x66 and report[5] != 1:
            return None
    elif ping_echo and report[6] != request[6]:
        return None
    return report[4:]


class BoltHidraw:
    def __init__(self, endpoint, deadline):
        self.path, self.sysfs, self.usb = endpoint
        self.deadline = deadline
        self.fd = None

    def __enter__(self):
        try:
            self.fd = os.open(self.path, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC | os.O_NOFOLLOW)
            info = os.fstat(self.fd)
            expected = (self.sysfs / "dev").read_text().strip()
            if (not stat.S_ISCHR(info.st_mode)
                    or expected != f"{os.major(info.st_rdev)}:{os.minor(info.st_rdev)}"
                    or usb_ancestor((self.sysfs / "device").resolve()) != self.usb):
                raise CompanionError("device_changed", "Bolt endpoint changed before opening")
            current = (self.sysfs / "device").resolve()
            interface = next((parent for parent in (current, *current.parents) if (parent / "bInterfaceNumber").is_file()), None)
            if interface is None or (interface / "bInterfaceNumber").read_text().strip() != "02":
                raise CompanionError("device_changed", "Bolt endpoint is no longer interface 02")
            raw_info = bytearray(8)
            fcntl.ioctl(self.fd, HIDIOCGRAWINFO, raw_info, True)
            bus, vendor, product = struct.unpack("=Ihh", raw_info)
            if (bus, vendor & 0xffff, product & 0xffff) != (3, 0x046d, 0xc548):
                raise CompanionError("device_changed", "Opened HID endpoint is not the Bolt USB receiver")
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return self
        except BlockingIOError as error:
            self.close()
            raise CompanionError("busy", "Another peripheral request owns the Bolt receiver") from error
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def __exit__(self, *_):
        self.close()

    def exchange(self, request, timeout=0.35, ping_echo=True):
        if time.monotonic() >= self.deadline:
            raise CompanionError("session_timeout", "Peripheral query reached its five-second deadline")
        deadline = min(self.deadline, time.monotonic() + timeout)
        for _ in range(32):
            if time.monotonic() >= deadline:
                raise CompanionError("send_timeout", "Bolt query could not be sent before its deadline")
            try:
                if not os.read(self.fd, 65):
                    raise CompanionError("disconnected", "Bolt receiver disconnected")
            except BlockingIOError:
                break
        else:
            raise CompanionError("noisy_endpoint", "Bolt endpoint has too much queued input")
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([], [self.fd], [], remaining)[1]:
            raise CompanionError("send_timeout", "Bolt query could not be sent before its deadline")
        if os.write(self.fd, request) != len(request):
            raise CompanionError("short_write", "Incomplete Bolt query; no retry sent")
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise CompanionError("reply_timeout", "Bolt query timed out")
            try:
                report = os.read(self.fd, 65)
            except BlockingIOError:
                continue
            if not report:
                raise CompanionError("disconnected", "Bolt receiver disconnected")
            payload = bolt_reply(report, request, ping_echo)
            if payload is not None:
                return payload


def peripheral_error(error):
    if isinstance(error, CompanionError):
        return str(error)[:512]
    if isinstance(error, PermissionError):
        return "Bolt's vendor HID++ interface needs read/write permission for this user"
    if isinstance(error, OSError) and error.errno in (errno.ENODEV, errno.ENXIO, errno.EIO):
        return "Bolt receiver disconnected"
    return "Could not read the Bolt receiver"


def paired_bolt_devices(transport, receiver):
    errors = []
    inaccessible_slots = []
    for slot in range(1, 7):
        if time.monotonic() >= transport.deadline:
            errors.append("Peripheral query reached its five-second deadline")
            break
        try:
            payload = transport.exchange(bytes((0x10, 0xff, 0x83, 0xb5, 0x50 + slot, 0, 0)))
        except (CompanionError, OSError) as error:
            # Neither a timeout nor a receiver error is evidence of an empty
            # pairing slot. Preserve an explicit incomplete-inventory error.
            message = f"Slot {slot}: {peripheral_error(error)}"
            if getattr(error, "code", "") == "hidpp_08":
                inaccessible_slots.append(message)
            else:
                errors.append(message)
            # Error replies do not echo the slot selector. After a timeout,
            # stop so a late reply cannot be assigned to the next slot.
            if not getattr(error, "code", "").startswith("hidpp_"):
                break
            continue
        device = {"slot": slot, "kind": {1: "keyboard", 2: "mouse"}.get(payload[1] & 15, "other"),
                  "wirelessProductID": payload[2:4][::-1].hex().upper(), "radio": "unavailable"}
        receiver["pairedDevices"].append(device)
        try:
            name = transport.exchange(bytes((0x10, 0xff, 0x83, 0xb5, 0x60 + slot, 1, 0)))
            length = name[2]
            text = name[3:3 + min(length, len(name) - 3)].decode("ascii")
            if any(ord(character) < 0x20 or ord(character) == 0x7f for character in text):
                raise CompanionError("invalid_name", "Bolt returned an invalid device name")
            if text:
                device["name"] = text
            if length > len(name) - 3:
                device["error"] = "Stored device name is truncated"
        except (CompanionError, OSError, UnicodeError) as error:
            device["error"] = peripheral_error(error)
            if not getattr(error, "code", "").startswith("hidpp_"):
                errors.append(f"Slot {slot}: {peripheral_error(error)}")
                break
        try:
            # Logitech IRoot.GetProtocolVersion: the device echoes pingData.
            # No notification flags, pairing commands or input events are used.
            mark = os.urandom(1)[0]
            ping = transport.exchange(bytes((0x10, slot, 0, 0x1b, 0, 0, mark)), 0.4)
            if ping[0] == 0:
                raise CompanionError("invalid_protocol", "Bolt returned an invalid protocol version")
            device["radio"] = "responding"
            device["protocolVersion"] = f"{ping[0]}.{ping[1]}"
        except (CompanionError, OSError) as error:
            if getattr(error, "code", "") in ("reply_timeout", "hidpp_04", "hidpp_09"):
                device["radio"] = "notResponding"
            device["error"] = peripheral_error(error)
            if isinstance(error, OSError) or getattr(error, "code", "") == "disconnected":
                errors.append(f"Slot {slot}: {peripheral_error(error)}")
                break
    # Live Bolt receivers return 08 for unused/inaccessible slots after their
    # valid pairings. Suppress that warning only with positive pairing evidence.
    if not receiver["pairedDevices"]:
        errors = inaccessible_slots + errors
    if errors:
        prefix = "" if receiver["pairedDevices"] else "No paired-device metadata was returned; receiver slots may be empty or unavailable. "
        receiver["error"] = (prefix + "; ".join(errors))[:512]


def peripheral_snapshot(topology=peripheral_topology, endpoint=bolt_endpoint, transport_type=BoltHidraw):
    snapshot = {"schemaVersion": 1, "checkedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "hostName": os.uname().nodename, "platform": "linux", "monitorHubPresent": False, "receivers": []}
    hub, receivers = topology()
    snapshot["monitorHubPresent"] = hub is not None
    for receiver, attached in receivers:
        snapshot["receivers"].append(receiver)
        if receiver["id"] != "bolt" or not attached:
            continue
        if len(attached) != 1:
            receiver["error"] = "More than one Bolt receiver is attached to the monitor hub"
            continue
        try:
            deadline = time.monotonic() + 5.0
            with transport_type(endpoint(attached[0]), deadline) as transport:
                paired_bolt_devices(transport, receiver)
        except (CompanionError, OSError) as error:
            receiver["error"] = peripheral_error(error)
    return snapshot


class POPDetailsProbe:
    """A fixed getter allowlist, never a generic HID++ command interface."""
    # Feature ID -> logical function ID -> exact parameter count.
    GETTERS = {
        0x0000: {0: 2}, 0x0001: {0: 0, 1: 1}, 0x0003: {0: 0, 1: 1},
        0x1004: {1: 0}, 0x1000: {0: 0}, 0x1001: {0: 0},
        0x40a2: {0: 0}, 0x40a0: {0: 0}, 0x1b04: {0: 0, 1: 1, 2: 2},
    }

    def __init__(self, transport, slot, expected_product):
        self.transport, self.slot, self.expected_product = transport, slot, expected_product.upper()
        self.software_id = os.urandom(1)[0] % 15 + 1
        self.stopped = False
        self.feature_set_index = None
        self.result = {
            "schemaVersion": 1, "hostName": os.uname().nodename, "platform": "linux",
            "slot": slot, "wirelessProductID": self.expected_product,
            "features": [], "featureInventoryComplete": False, "firmware": [],
            "controls": [], "controlInventoryComplete": False, "errors": [],
        }

    def error(self, message):
        self.result["errors"].append(message[:512])

    def feature(self, identifier):
        return next((feature for feature in self.result["features"]
                     if feature["id"] == identifier and feature["index"] > 0), None)

    def get(self, feature, function, parameters=b"", length=1):
        allowed = self.GETTERS.get(feature, {})
        if (allowed.get(function) != len(parameters) or len(parameters) > 3
                or (feature == 0 and parameters != b"\0\x01")):
            raise CompanionError("invalid_query", "POP details getter is not allowed")
        if self.stopped:
            raise CompanionError("session_stopped", "Remaining POP details were not read")
        if feature == 0:
            index = 0
        elif feature == 1 and self.feature_set_index is not None:
            index = self.feature_set_index
        else:
            advertised = self.feature(feature)
            if advertised is None:
                raise CompanionError("unsupported_feature", "POP details feature was not advertised")
            index = advertised["index"]
        self.software_id = self.software_id % 15 + 1
        packet = bytes((0x10, self.slot, index, function << 4 | self.software_id)) + parameters.ljust(3, b"\0")
        try:
            payload = self.transport.exchange(packet, ping_echo=False)
        except (CompanionError, OSError) as error:
            if not getattr(error, "code", "").startswith(("hidpp_", "hidpp2_")):
                self.stopped = True
            if getattr(error, "code", "") == "session_timeout":
                raise CompanionError("session_timeout", "POP details reached the eight-second deadline") from error
            raise
        if len(payload) < length:
            raise CompanionError("invalid_reply", "POP getter returned an incomplete response")
        # Discard unused fields such as firmware GetInfo's unit ID here.
        return payload[:length]

    def read(self):
        pairing = self.transport.exchange(bytes((0x10, 0xff, 0x83, 0xb5, 0x50 + self.slot, 0, 0)))
        if (len(pairing) < 4 or pairing[1] & 15 != 1
                or pairing[2:4][::-1].hex().upper() != self.expected_product):
            raise CompanionError("device_changed", "POP keyboard identity changed; refresh peripherals")
        named = self.transport.exchange(bytes((0x10, 0xff, 0x83, 0xb5, 0x60 + self.slot, 1, 0)))
        if len(named) < 3 or named[2] > len(named) - 3:
            raise CompanionError("device_changed", "POP keyboard name is unavailable or truncated")
        try:
            name = named[3:3 + named[2]].decode("ascii")
        except UnicodeError as error:
            raise CompanionError("device_changed", "POP keyboard name is invalid") from error
        if name not in ("Logi POP Keys", "POP Keys"):
            raise CompanionError("device_changed", "The selected receiver slot is not a POP Keys keyboard")
        mark = os.urandom(1)[0]
        ping = self.transport.exchange(bytes((0x10, self.slot, 0, 0x10 | self.software_id, 0, 0, mark)), 0.4)
        if len(ping) < 3 or ping[0] < 2:
            raise CompanionError("device_changed", "POP keyboard did not return a current HID++ 2 protocol response")
        self.result["name"] = name
        sections = (("Feature discovery", self.discover_features), ("Firmware", self.read_firmware),
                    ("Battery", self.read_battery), ("Function-key mode", self.read_fn_mode),
                    ("Control mappings", self.read_controls))
        for label, read in sections:
            if self.stopped:
                break
            try:
                read()
            except (CompanionError, OSError) as error:
                self.error(f"{label}: {peripheral_error(error)}")
        self.result["checkedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        return self.result

    def discover_features(self):
        root = self.get(0, 0, b"\0\x01", 3)
        if root[0] == 0:
            raise CompanionError("unsupported_feature", "FeatureSet is unavailable")
        self.feature_set_index = root[0]
        count = self.get(1, 0)[0] + 1  # FeatureSet count excludes root.
        complete = count <= 64
        if not complete:
            self.error("Feature inventory exceeds the 64-entry read limit")
        for index in range(min(count, 64)):
            try:
                data = self.get(1, 1, bytes((index,)), 4)
                identifier = int.from_bytes(data[:2], "big")
                if any(feature["id"] == identifier for feature in self.result["features"]):
                    raise CompanionError("invalid_reply", "Feature inventory contains a duplicate identifier")
                self.result["features"].append({"id": identifier, "index": index, "version": data[3], "flags": data[2]})
            except (CompanionError, OSError) as error:
                complete = False
                self.error(f"Feature index {index}: {peripheral_error(error)}")
                if self.stopped:
                    break
        self.result["featureInventoryComplete"] = complete and len(self.result["features"]) == count

    def read_firmware(self):
        if self.feature(3) is None:
            return
        count = self.get(3, 0)[0]
        if count > 8:
            self.error("Firmware inventory exceeds the 8-entry read limit")
        for index in range(min(count, 8)):
            data = self.get(3, 1, bytes((index,)), 8)
            kind = data[0] & 15
            if kind in (0, 1):
                if any(byte < 32 or byte > 126 for byte in data[1:4]):
                    raise CompanionError("invalid_reply", "Firmware prefix is not printable ASCII")
                firmware = {"kind": "firmware" if kind == 0 else "bootloader", "prefix": data[1:4].decode("ascii"),
                            "version": f"{data[4]:02X}.{data[5]:02X}", "build": int.from_bytes(data[6:8], "big")}
            elif kind == 2:
                firmware = {"kind": "hardware", "version": str(data[1])}
            else:
                firmware = {"kind": "other"}
            self.result["firmware"].append(firmware)

    def read_battery(self):
        identifier = next((value for value in (0x1004, 0x1000, 0x1001) if self.feature(value)), None)
        if identifier is None:
            return
        data = self.get(identifier, 1 if identifier == 0x1004 else 0, length=4 if identifier == 0x1004 else 3)
        battery = {"featureID": identifier}
        if identifier == 0x1001:
            battery["voltageMillivolts"] = int.from_bytes(data[:2], "big")
        else:
            if data[0] > 100:
                raise CompanionError("invalid_reply", "Invalid battery percentage")
            if data[0]:
                battery["percentage"] = data[0]
            battery["statusCode"] = data[2]
            if identifier == 0x1004:
                level = {1: "critical", 2: "low", 4: "good", 8: "full"}.get(data[1])
                if level:
                    battery["level"] = level
        self.result["battery"] = battery

    def read_fn_mode(self):
        if self.feature(0x40a2):
            data = self.get(0x40a2, 0, length=2)
            self.result["fnMode"] = {"featureID": 0x40a2, "inverted": bool(data[0] & 1), "defaultInverted": bool(data[1] & 1)}
        elif self.feature(0x40a0):
            data = self.get(0x40a0, 0)
            if data[0] > 1:
                raise CompanionError("invalid_reply", "Invalid function-key mode")
            self.result["fnMode"] = {"featureID": 0x40a0, "inverted": bool(data[0])}
        elif self.feature(0x40a3):
            self.error("Host-specific function-key mode is advertised; its current host setting is not read")

    def read_controls(self):
        if self.feature(0x1b04) is None:
            return
        count = self.get(0x1b04, 0)[0]
        complete = count <= 32
        if not complete:
            self.error("Control inventory exceeds the 32-entry read limit")
        for index in range(min(count, 32)):
            data = self.get(0x1b04, 1, bytes((index,)), 9)
            cid = int.from_bytes(data[:2], "big")
            if any(control["controlID"] == cid for control in self.result["controls"]):
                raise CompanionError("invalid_reply", "Control inventory contains a duplicate identifier")
            control = {"controlID": cid, "defaultTaskID": int.from_bytes(data[2:4], "big"),
                       "flags": data[4] | data[8] << 8, "position": data[5], "group": data[6], "groupMask": data[7]}
            try:
                mapping = self.get(0x1b04, 2, data[:2], 6)
                if mapping[:2] != data[:2]:
                    raise CompanionError("invalid_reply", "Control mapping did not echo its identifier")
                control["currentControlID"] = int.from_bytes(mapping[3:5], "big") or cid
                control["reportingFlags"] = mapping[2] | mapping[5] << 8
            except (CompanionError, OSError) as error:
                complete = False
                self.error(f"Control 0x{cid:04X}: {peripheral_error(error)}")
            self.result["controls"].append(control)
            if self.stopped:
                break
        self.result["controlInventoryComplete"] = complete and len(self.result["controls"]) == count


def pop_details(request, topology=peripheral_topology, endpoint=bolt_endpoint, transport_type=BoltHidraw):
    try:
        hub, receivers = topology()
        attached = next(paths for receiver, paths in receivers if receiver["id"] == "bolt")
        if hub is None or not attached:
            raise CompanionError("not_present", "A Bolt receiver is not attached to this computer through the monitor hub")
        if len(attached) != 1:
            raise CompanionError("ambiguous_receiver", "More than one Bolt receiver is attached to the monitor hub")
        deadline = time.monotonic() + 8.0
        with transport_type(endpoint(attached[0]), deadline) as transport:
            return POPDetailsProbe(transport, request["slot"], request["expectedWirelessProductID"]).read(), 0
    except (CompanionError, OSError) as error:
        message = "POP details reached the eight-second deadline" if getattr(error, "code", "") == "session_timeout" else peripheral_error(error)
        return {"schemaVersion": 1, "action": "popDetails",
                "error": {"code": getattr(error, "code", "io_error"), "message": message}}, 2


def execute(request, find_device=discover, transport_type=Hidraw):
    if request["action"] == "peripherals":
        return peripheral_snapshot(), 0
    if request["action"] == "layout":
        return layout_snapshot(find_device, transport_type)
    if request["action"] == "popDetails":
        return pop_details(request)
    result = {"schemaVersion": SCHEMA_VERSION, "action": request["action"],
              "present": False, "accessible": False, "state": None,
              "writeAttempted": False, "writeCompleted": False,
              "acknowledged": False, "verified": False}
    transport = None
    try:
        device = find_device()
        if device is None:
            if request["action"] == "setKVM":
                raise CompanionError("not_present", "MSI USB controller is not connected to this computer")
            result["outcome"] = "not_present"
            return result, 0
        result["present"] = True
        if not os.access(device[0], os.R_OK | os.W_OK):
            raise PermissionError("MSI hidraw access denied")
        with transport_type(device) as transport:
            result["accessible"] = True
            state = read_state(transport)
            result["state"] = state
            if request["action"] == "status":
                result.update(outcome="observed", verified=True)
                return result, 0
            result["target"] = request["target"]
            if state["kvm"] != request["expected"]:
                raise CompanionError("stale_state", "KVM route changed since planning; read status again")
            if state["kvm"] == request["target"]:
                result.update(outcome="unchanged", verified=True)
                return result, 0
            # Live handoffs move this controller before an ACK arrives. Send
            # once, then let the coordinator verify from the destination host.
            transport.send(b"5b" + KVM_REGISTER + ROUTES[request["target"]], mutation=True)
            result.update(writeAttempted=True, writeCompleted=True, outcome="sent")
            return result, 0
    except (CompanionError, OSError) as error:
        result["error"] = error_details(error)
        if transport is not None:
            result["writeAttempted"] = transport.write_attempted
            result["writeCompleted"] = transport.write_completed
        result["outcome"] = "unverified" if result["writeAttempted"] else "failed"
        return result, 2


def main():
    try:
        result, code = execute(read_request())
    except (CompanionError, OSError) as error:
        result, code = {"schemaVersion": SCHEMA_VERSION, "outcome": "failed",
                        "writeAttempted": False, "verified": False,
                        "error": error_details(error)}, 2
    # Peripheral names are bounded and decoded; serials and raw reports are omitted.
    sys.stdout.write(json.dumps(result, separators=(",", ":")) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
