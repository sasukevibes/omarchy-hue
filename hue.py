#!/usr/bin/env python3
"""Small, dependency-free Philips Hue v1 client for the Omarchy widget."""

from __future__ import annotations

import argparse
import array
import colorsys
import json
import math
import os
import random
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

STATE = Path.home() / ".local/state/omarchy/hue.json"
AMBIENT_STATE = Path.home() / ".local/state/omarchy/hue-ambient.json"
LIGHTSHOW_STATE = Path.home() / ".local/state/omarchy/hue-lightshow.json"
TIMEOUT = 3

# Hue v1 group/light identifiers are always small decimal integers, and the
# bridge is always addressed by IPv4 on the local network. Both values flow
# straight into a request path/URL below, so they're validated up front
# rather than trusted as opaque strings.
ID_RE = re.compile(r"^[0-9]{1,8}$")
IPV4_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")
# Wayland output names (from `hyprctl monitors`), e.g. "DP-1", "eDP-1".
MONITOR_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def valid_id(value):
    if not ID_RE.match(str(value)):
        raise RuntimeError("Invalid identifier")
    return str(value)


def valid_ip(value):
    if not IPV4_RE.match(str(value)) or any(int(part) > 255 for part in str(value).split(".")):
        raise RuntimeError("Invalid bridge address")
    return str(value)


def valid_monitor(value):
    value = str(value or "all")
    if value == "all" or MONITOR_RE.match(value):
        return value
    raise RuntimeError("Invalid monitor")


def valid_colors(value):
    parts = [p for p in str(value or "").split(",") if p != ""]
    if not 4 <= len(parts) <= 6:
        raise RuntimeError("Pick between 4 and 6 colours")
    colors = []
    for part in parts:
        if not re.match(r"^-?[0-9]+$", part):
            raise RuntimeError("Invalid colour value")
        colors.append(int(part) % 65536)
    return colors


def emit(value):
    print(json.dumps(value, separators=(",", ":")))


def load_config():
    try:
        value = json.loads(STATE.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save_config(value):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(STATE.parent, 0o700)
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(STATE)


def load_ambient_state():
    try:
        value = json.loads(AMBIENT_STATE.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save_ambient_state(value):
    AMBIENT_STATE.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(AMBIENT_STATE.parent, 0o700)
    temporary = AMBIENT_STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(AMBIENT_STATE)


def _pid_alive(pid):
    if not isinstance(pid, int):
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def save_ambient_state_if_owner(pid, value):
    # A daemon superseded by a newer `ambient-start` (or stopped explicitly)
    # must not let its own async cleanup clobber the record afterwards —
    # only write if the state file still names this process as current.
    if load_ambient_state().get("pid") == pid:
        save_ambient_state(value)


def ambient_status():
    state = load_ambient_state()
    if state.get("active") and not _pid_alive(state.get("pid")):
        state = {"active": False, "room": state.get("room", ""), "monitor": state.get("monitor", "all")}
        save_ambient_state(state)
    return {"active": bool(state.get("active")), "room": str(state.get("room", "")),
            "monitor": state.get("monitor", "all"), "error": state.get("error", "")}


def load_lightshow_state():
    try:
        value = json.loads(LIGHTSHOW_STATE.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def save_lightshow_state(value):
    LIGHTSHOW_STATE.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(LIGHTSHOW_STATE.parent, 0o700)
    temporary = LIGHTSHOW_STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(LIGHTSHOW_STATE)


def save_lightshow_state_if_owner(pid, value):
    if load_lightshow_state().get("pid") == pid:
        save_lightshow_state(value)


def lightshow_status():
    state = load_lightshow_state()
    if state.get("active") and not _pid_alive(state.get("pid")):
        state = {"active": False, "room": state.get("room", ""), "colors": state.get("colors", [])}
        save_lightshow_state(state)
    return {"active": bool(state.get("active")), "room": str(state.get("room", "")),
            "colors": state.get("colors", []), "error": state.get("error", "")}


def set_ambient_exclusion(light, excluded):
    # Ambient mode pushes one room-wide "on" action per tick, which would
    # otherwise fight anyone who turns an individual light off while it's
    # running. A light explicitly turned off is excluded from that room-wide
    # push until it's turned back on (whether via the power toggle or any
    # brightness/colour change, which already imply "on"). Session-scoped:
    # a fresh `ambient-start` resets the exclusion list. Harmless no-op if
    # ambient isn't running, or if this light isn't in the room it's
    # currently syncing — the loop only ever consults this for its own
    # room's lights.
    state = load_ambient_state()
    if not state.get("active"):
        return
    lights = set(state.get("excluded", []))
    if excluded:
        lights.add(str(light))
    else:
        lights.discard(str(light))
    state["excluded"] = sorted(lights)
    save_ambient_state(state)


def set_lightshow_exclusion(light, excluded):
    # Mirrors set_ambient_exclusion: a light turned off during a light show
    # is excluded from its per-light PUTs (paused, not cycling) until it's
    # turned back on. Unlike ambient mode, a paused light's own remembered
    # colour is already the show's current phase for it — nothing else was
    # touching it while excluded — so no separate resync-on-rejoin is
    # needed; turning it back on just shows what it already had.
    state = load_lightshow_state()
    if not state.get("active"):
        return
    lights = set(state.get("excluded", []))
    if excluded:
        lights.add(str(light))
    else:
        lights.discard(str(light))
    state["excluded"] = sorted(lights)
    save_lightshow_state(state)


def room_light_ids(room):
    group = api(f"groups/{valid_id(room)}")
    return [str(item) for item in group.get("lights", [])]


def request(url, method="GET", payload=None, timeout=TIMEOUT):
    body = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode())


def bridge_config(ip):
    value = request(f"http://{valid_ip(ip)}/api/config")
    if not isinstance(value, dict) or not value.get("bridgeid"):
        raise RuntimeError("Not a Hue bridge")
    return value


def discover_ssdp():
    message = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
               "MAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n").encode()
    found = []
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.settimeout(0.35)
    try:
        sock.sendto(message, ("239.255.255.250", 1900))
        while True:
            try:
                data, address = sock.recvfrom(65535)
            except socket.timeout:
                break
            text = data.decode(errors="ignore")
            if "hue-bridgeid" in text.lower() or "philips-hue" in text.lower():
                found.append(address[0])
    finally:
        sock.close()
    return found


def discover_avahi():
    """Resolve Hue's local mDNS service when Avahi is available."""
    try:
        result = subprocess.run(["avahi-browse", "-rtp", "_hue._tcp"],
                                capture_output=True, text=True, timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return []
    addresses = []
    for line in result.stdout.splitlines():
        fields = line.split(";")
        if line.startswith("=") and len(fields) > 8 and fields[7]:
            addresses.append(fields[7])
    return addresses


def discover():
    configured = load_config().get("ip")
    candidates = [configured] if configured else []
    candidates += discover_avahi()
    try:
        candidates += discover_ssdp()
    except OSError:
        # Some restricted launch contexts disallow multicast sockets. The
        # bridge's official discovery endpoint remains a useful fallback.
        pass
    try:
        candidates += [item.get("internalipaddress") for item in
                       request("https://discovery.meethue.com/", timeout=4)]
    except Exception:
        pass
    seen = set()
    bridges = []
    for ip in candidates:
        if not ip or ip in seen:
            continue
        seen.add(ip)
        try:
            cfg = bridge_config(ip)
            bridges.append({"ip": ip, "id": cfg.get("bridgeid", ""),
                            "name": cfg.get("name", "Hue Bridge")})
        except Exception:
            pass
    return bridges


def api(path, method="GET", payload=None):
    cfg = load_config()
    if not cfg.get("ip") or not cfg.get("username"):
        raise RuntimeError("Bridge is not paired")
    result = request(f"http://{valid_ip(cfg['ip'])}/api/{cfg['username']}/{path.lstrip('/')}",
                     method, payload)
    if isinstance(result, list):
        for item in result:
            if isinstance(item, dict) and "error" in item:
                raise RuntimeError(item["error"].get("description", "Hue API error"))
    return result


def pair(ip):
    ip = valid_ip(ip)
    cfg = bridge_config(ip)
    result = request(f"http://{ip}/api", "POST", {"devicetype": "omarchy_hue_widget"})
    if not result or "success" not in result[0]:
        description = result[0].get("error", {}).get("description", "Pairing failed")
        raise RuntimeError(description)
    state = {"ip": ip, "bridge_id": cfg.get("bridgeid", ""),
             "bridge_name": cfg.get("name", "Hue Bridge"),
             "username": result[0]["success"]["username"]}
    save_config(state)
    return state


def snapshot():
    cfg = load_config()
    if not cfg.get("username"):
        bridges = discover()
        return {"paired": False, "bridges": bridges, "ambient": ambient_status(),
                "lightshow": lightshow_status(),
                "message": "Bridge found — press its link button, then Pair" if bridges
                           else "Searching for a Hue bridge on this network"}
    groups = api("groups")
    scenes = api("scenes")
    lights = api("lights")
    rooms = []
    for group_id, group in groups.items():
        if group.get("type") != "Room":
            continue
        action = group.get("action", {})
        state = group.get("state", {})
        room_scenes = []
        for scene_id, scene in scenes.items():
            if str(scene.get("group", "")) == str(group_id):
                room_scenes.append({"id": scene_id, "name": scene.get("name", "Scene")})
        room_scenes.sort(key=lambda x: x["name"].lower())
        room_lights = []
        for light_id in group.get("lights", []):
            light = lights.get(str(light_id))
            if not light:
                continue
            light_state = light.get("state", {})
            room_lights.append({"id": light_id, "name": light.get("name", f"Light {light_id}"),
                                "on": bool(light_state.get("on", False)),
                                "brightness": int(light_state.get("bri", 0)),
                                "hue": int(light_state.get("hue", 0)),
                                "sat": int(light_state.get("sat", 0)),
                                "reachable": bool(light_state.get("reachable", True))})
        room_lights.sort(key=lambda x: x["name"].lower())
        rooms.append({"id": group_id, "name": group.get("name", f"Room {group_id}"),
                      "on": bool(state.get("any_on", action.get("on", False))),
                      "all_on": bool(state.get("all_on", False)),
                      "brightness": int(action.get("bri", 0)), "scenes": room_scenes,
                      "lights": room_lights})
    rooms.sort(key=lambda x: x["name"].lower())
    return {"paired": True, "bridge": cfg.get("bridge_name", "Hue Bridge"), "rooms": rooms,
            "ambient": ambient_status(), "lightshow": lightshow_status()}


def set_room(room, payload):
    api(f"groups/{valid_id(room)}/action", "PUT", payload)
    return snapshot()


def set_light(light, payload):
    api(f"lights/{valid_id(light)}/state", "PUT", payload)
    if "on" in payload:
        set_ambient_exclusion(light, excluded=not payload["on"])
        set_lightshow_exclusion(light, excluded=not payload["on"])
    return snapshot()


def list_monitors():
    result = subprocess.run(["hyprctl", "monitors", "-j"], capture_output=True,
                            timeout=2, check=True, text=True)
    data = json.loads(result.stdout)
    return [item["name"] for item in data if isinstance(item, dict) and item.get("name")]


def monitors():
    try:
        return {"monitors": list_monitors()}
    except Exception:
        return {"monitors": []}


def is_locked():
    try:
        result = subprocess.run(["pgrep", "-x", "hyprlock"], capture_output=True, timeout=1)
        return result.returncode == 0
    except OSError:
        return False


def _grim_ppm(output, scale=0.12):
    args = ["grim", "-t", "ppm", "-s", str(scale)]
    if output:
        args += ["-o", output]
    args.append("-")
    result = subprocess.run(args, capture_output=True, timeout=2, check=True)
    return result.stdout


def _average_ppm(data):
    if not data.startswith(b"P6"):
        raise RuntimeError("Unexpected grim output")
    fields = []
    i = 2
    while len(fields) < 3:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] != b"\n":
                i += 1
            continue
        start = i
        while not data[i:i + 1].isspace():
            i += 1
        fields.append(int(data[start:i]))
    width, height, maxval = fields
    pixels = data[i + 1:]
    count = width * height
    if len(pixels) < count * 3:
        raise RuntimeError("Truncated grim output")
    # Already downscaled by -s, so a full pass is cheap; the stride only
    # guards against an unexpectedly large/high-DPI output.
    stride = max(1, count // 20000)
    r_total = g_total = b_total = sampled = 0
    for p in range(0, count, stride):
        o = p * 3
        r_total += pixels[o]
        g_total += pixels[o + 1]
        b_total += pixels[o + 2]
        sampled += 1
    scale_factor = 255 / maxval if maxval != 255 else 1
    return (r_total / sampled * scale_factor, g_total / sampled * scale_factor,
            b_total / sampled * scale_factor)


def sample_screen(monitor):
    outputs = list_monitors() if monitor == "all" else [monitor]
    if not outputs:
        raise RuntimeError("No active monitor")
    totals = [0.0, 0.0, 0.0]
    for name in outputs:
        rgb = _average_ppm(_grim_ppm(name))
        for i in range(3):
            totals[i] += rgb[i]
    n = len(outputs)
    return totals[0] / n, totals[1] / n, totals[2] / n


def _clamp(value, lo, hi):
    return max(lo, min(hi, value))


def rgb_to_hue_sat_bri(r, g, b):
    h, s, v = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
    hue = int(h * 65535) % 65536
    sat = int(s * 254)
    # A grey/near-black frame (a dark terminal, a code editor) would otherwise
    # desaturate the lights to a flat white; keep some colour on screen.
    if v > 0.03:
        sat = max(sat, 40)
    bri = _clamp(int(v * 254), 25, 254)
    return hue, _clamp(sat, 0, 254), bri


def _changed_enough(prev, curr):
    ph, ps, pb = prev
    ch, cs, cb = curr
    return abs(ph - ch) > 400 or abs(ps - cs) > 6 or abs(pb - cb) > 3


def _default_sink_monitor():
    try:
        result = subprocess.run(["pactl", "get-default-sink"], capture_output=True,
                                timeout=2, check=True, text=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    name = result.stdout.strip()
    if not name or name.startswith("bluez_"):
        # Confirmed on real hardware: opening *any* capture stream linked to
        # a Bluetooth card — even one that only targets the sink's monitor,
        # never the microphone — makes PipeWire/WirePlumber renegotiate the
        # device onto the bidirectional HSP/HFP profile anyway, degrading
        # output to low-quality mono with mic sidetone for as long as the
        # capture runs. There's no known way to tap a Bluetooth A2DP sink's
        # monitor from here without risking that, so skip audio entirely
        # when Bluetooth is the output — ambient mode still runs, just
        # without the audio-driven brightness pulse.
        return None
    return f"{name}.monitor"


class AudioEnvelope:
    """Smoothed 0..1 loudness of the default sink's monitor, captured via
    PipeWire. Auto-gains between a slow-tracking noise floor and a
    slow-decaying peak so quiet and loud sources both land in a usable
    range, and constant background noise (mains hum, ADC self-noise, true
    silence) reads as ~0 rather than pegging at max; degrades to a flat 0
    (pure screen-driven brightness, no boost) if pw-record/pactl aren't
    installed or no default sink can be resolved."""

    def __init__(self):
        self._proc = None
        self._thread = None
        self._lock = threading.Lock()
        self._level = 0.0
        self._floor = 0.0
        self._peak = 1.0

    def start(self):
        # Explicitly target the default *sink's monitor*, never PipeWire's
        # default *source*. Left unset, pw-record falls back to the default
        # source — which on a Bluetooth headset is its microphone, and
        # opening that forces the headset off the high-quality A2DP sink
        # profile onto the low-quality bidirectional HSP/HFP call profile,
        # audibly degrading or dropping output audio for as long as ambient
        # mode runs. The monitor of the *sink* carries whatever's already
        # playing and never touches profile negotiation.
        target = _default_sink_monitor()
        if not target:
            return
        try:
            self._proc = subprocess.Popen(
                # --container raw: pw-record's default stdout container is a
                # Sun/NeXT AU file (a 24-byte header before the PCM data), not
                # headerless PCM. Without this, the header's own bytes get
                # parsed as if they were the first few audio samples.
                ["pw-record", "--container", "raw", "--target", target,
                 "--channels", "1", "--rate", "8000", "--format", "s16", "-"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            return
        self._thread = threading.Thread(target=self._read_loop, daemon=True)
        self._thread.start()

    def _read_loop(self):
        chunk_bytes = 1600  # 200ms of mono 16-bit audio at 8kHz
        while self._proc is not None:
            data = self._proc.stdout.read(chunk_bytes)
            if not data:
                return
            samples = array.array("h")
            samples.frombytes(data[:len(data) - (len(data) % 2)])
            if not samples:
                continue
            rms = math.sqrt(sum(s * s for s in samples) / len(samples))
            with self._lock:
                # Real hardware noise floors vary hugely — a clean interface
                # reads near-zero at idle, a noisy onboard codec can sit at a
                # few thousand (out of 32767) with nothing playing. The floor
                # tracks that baseline, seeded from the first sample so
                # silence doesn't misread as loud during the EMA's warm-up.
                # The span between floor and peak is bounded to a fraction of
                # the floor itself (not a fixed constant) so a noisy floor's
                # own jitter doesn't get mistaken for the full loud range,
                # and so a quiet interface's tiny floor still gets a usable
                # amount of headroom to react in.
                if self._floor == 0.0:
                    self._floor = rms
                elif rms < self._floor * 2.0:
                    self._floor = self._floor * 0.98 + rms * 0.02
                self._peak = max(rms, self._peak * 0.999, self._floor * 1.5)
                span = max(self._peak - self._floor, self._floor * 0.5, 150.0)
                target = _clamp((rms - self._floor) / span, 0.0, 1.0)
                self._level = self._level * 0.6 + target * 0.4

    def level(self):
        with self._lock:
            return self._level

    def stop(self):
        proc, self._proc = self._proc, None
        if proc:
            proc.terminate()


def run_ambient_loop(room, monitor):
    tick = 0.3
    pid = os.getpid()
    try:
        sample_screen(monitor)
    except FileNotFoundError as error:
        save_ambient_state_if_owner(pid, {"active": False, "room": room, "monitor": monitor,
                                          "error": f"Missing dependency: {error.filename or error}"})
        return
    except Exception:
        pass  # transient (e.g. a locked screen at startup); the loop below retries

    audio = AudioEnvelope()
    audio.start()
    last_hsb = None
    last_excluded = set()
    try:
        while True:
            if is_locked():
                time.sleep(1.0)
                continue
            try:
                rgb = sample_screen(monitor)
            except Exception:
                time.sleep(1.0)
                continue
            hue, sat, base_bri = rgb_to_hue_sat_bri(*rgb)
            # A real "dancing with the music" look needs quiet moments to
            # visibly dip, not just loud ones to nudge upward — a ~220-unit
            # swing (over 80% of Hue's 1-254 range) centered so silence pulls
            # brightness down and peaks push it toward full, rather than the
            # small one-directional +70 boost this started as.
            bri = _clamp(base_bri + int((audio.level() - 0.3) * 220), 1, 254)
            hsb = (hue, sat, bri)
            state = load_ambient_state()
            excluded = set(state.get("excluded", [])) if state.get("pid") == pid else set()
            # A light rejoining (or leaving) the sync should snap to the
            # current colour right away, not wait for the next incidental
            # screen-colour change — otherwise a just-re-included light can
            # sit visibly stale for however long the screen stays static.
            exclusion_changed = excluded != last_excluded
            last_excluded = excluded
            if last_hsb is None or _changed_enough(last_hsb, hsb) or exclusion_changed:
                payload = {"on": True, "hue": hue, "sat": sat, "bri": bri, "transitiontime": 3}
                try:
                    if excluded:
                        # A light's been manually turned off — drop to
                        # per-light PUTs so the room-wide action doesn't
                        # turn it back on every tick.
                        for light_id in room_light_ids(room):
                            if light_id not in excluded:
                                try:
                                    api(f"lights/{light_id}/state", "PUT", payload)
                                except Exception:
                                    pass
                    else:
                        api(f"groups/{room}/action", "PUT", payload)
                except Exception:
                    pass
                last_hsb = hsb
            time.sleep(tick)
    finally:
        audio.stop()
        save_ambient_state_if_owner(pid, {"active": False, "room": room, "monitor": monitor})


def stop_ambient(quiet=False):
    state = load_ambient_state()
    pid = state.get("pid")
    if pid and _pid_alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    save_ambient_state({"active": False, "room": state.get("room", ""),
                        "monitor": state.get("monitor", "all")})
    return None if quiet else snapshot()


def ambient_start(room, monitor):
    room = valid_id(room)
    monitor = valid_monitor(monitor)
    cfg = load_config()
    if not cfg.get("username"):
        raise RuntimeError("Bridge is not paired")
    stop_ambient(quiet=True)
    stop_lightshow(quiet=True)  # only one dynamic lighting mode runs at a time

    child_pid = os.fork()
    if child_pid > 0:
        # Written here, not by the child: the child's first loop tick (a
        # screen capture + bridge PUT) can take a moment, and snapshot()
        # below must already reflect "active" so the toggle updates without
        # waiting for the next periodic refresh.
        save_ambient_state({"active": True, "room": room, "monitor": monitor, "pid": child_pid,
                            "excluded": []})
        return snapshot()

    # Single fork + setsid: the child is reparented to init and keeps running
    # after this CLI invocation exits, which is the whole point — ambient
    # sync outlives the QML panel that started it. Redirecting stdio to
    # /dev/null immediately closes our end of the parent's stdout pipe, so
    # Quickshell's StdioCollector still sees a clean EOF right after the
    # parent's own snapshot() print, instead of blocking on this daemon.
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    if devnull > 2:
        os.close(devnull)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    try:
        run_ambient_loop(room, monitor)
    finally:
        os._exit(0)


def run_lightshow_loop(room, colors):
    pid = os.getpid()
    try:
        lights = room_light_ids(room)
    except Exception:
        save_lightshow_state_if_owner(pid, {"active": False, "room": room, "colors": colors,
                                            "error": "Could not read this room's lights"})
        return
    if not lights:
        save_lightshow_state_if_owner(pid, {"active": False, "room": room, "colors": colors,
                                            "error": "This room has no individually addressable lights"})
        return

    audio = AudioEnvelope()
    audio.start()
    now = time.time()
    # Stagger each light's starting colour and next-change time so the room
    # never reads as one flat flip — from tick one, every light is already
    # mid-way through its own independent cycle through the palette.
    phase = {}
    for i, light_id in enumerate(lights):
        index = i % len(colors)
        phase[light_id] = {"index": index, "next": now + random.uniform(0, 1.6)}
        try:
            api(f"lights/{light_id}/state", "PUT",
                {"on": True, "hue": colors[index], "sat": 254, "bri": 200, "transitiontime": 1})
        except Exception:
            pass

    # Loud music drives the interval all the way down to min_interval, sized
    # to this room's light count so a synced-up burst across every light
    # still can't sustain more than ~8 req/sec against the Hue bridge's
    # ~10 req/sec guidance — a fixed floor would let a big room's flashing
    # overload the bridge under sustained loud audio.
    min_interval = max(0.4, len(lights) / 8.0)
    jitter_span = min_interval * 0.3

    try:
        while True:
            now = time.time()
            level = audio.level()
            # Loud music -> faster flashing and brighter peaks; quiet or no
            # audio -> still a snappy ~1.6s cycle, never a slow fade. A
            # near-instant transitiontime (versus a multi-second crossfade)
            # is what actually reads as "flashing" rather than "drifting".
            base_interval = min_interval + (1.6 - min_interval) * (1.0 - level)
            bri = _clamp(180 + int((level - 0.2) * 220), 60, 254)
            state = load_lightshow_state()
            excluded = set(state.get("excluded", [])) if state.get("pid") == pid else set()
            for light_id in lights:
                if light_id in excluded:
                    # Paused, not cycling — nothing else touches this light
                    # while it's off, so its own remembered colour is
                    # already the show's current phase for it; turning it
                    # back on just shows that, no separate resync needed.
                    continue
                light_phase = phase[light_id]
                if now >= light_phase["next"]:
                    light_phase["index"] = (light_phase["index"] + 1) % len(colors)
                    light_phase["next"] = now + base_interval + random.uniform(-jitter_span, jitter_span)
                    try:
                        api(f"lights/{light_id}/state", "PUT",
                            {"on": True, "hue": colors[light_phase["index"]], "sat": 254,
                             "bri": bri, "transitiontime": 1})
                    except Exception:
                        pass
            time.sleep(0.1)  # fine-grained enough to hit sub-second intervals precisely
    finally:
        audio.stop()
        save_lightshow_state_if_owner(pid, {"active": False, "room": room, "colors": colors})


def stop_lightshow(quiet=False):
    state = load_lightshow_state()
    pid = state.get("pid")
    if pid and _pid_alive(pid):
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    save_lightshow_state({"active": False, "room": state.get("room", ""),
                          "colors": state.get("colors", [])})
    return None if quiet else snapshot()


def lightshow_start(room, colors_arg):
    room = valid_id(room)
    colors = valid_colors(colors_arg)
    cfg = load_config()
    if not cfg.get("username"):
        raise RuntimeError("Bridge is not paired")
    stop_lightshow(quiet=True)
    stop_ambient(quiet=True)  # only one dynamic lighting mode runs at a time

    child_pid = os.fork()
    if child_pid > 0:
        save_lightshow_state({"active": True, "room": room, "colors": colors, "pid": child_pid,
                              "excluded": []})
        return snapshot()

    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    if devnull > 2:
        os.close(devnull)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    try:
        run_lightshow_loop(room, colors)
    finally:
        os._exit(0)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    pairing = sub.add_parser("pair")
    pairing.add_argument("ip")
    power = sub.add_parser("power")
    power.add_argument("room")
    power.add_argument("value", choices=("on", "off"))
    brightness = sub.add_parser("brightness")
    brightness.add_argument("room")
    brightness.add_argument("value", type=int)
    colour = sub.add_parser("colour")
    colour.add_argument("room")
    colour.add_argument("hue", type=int)
    colour.add_argument("sat", type=int, nargs="?", default=220)
    scene = sub.add_parser("scene")
    scene.add_argument("room")
    scene.add_argument("scene")
    light_power = sub.add_parser("light-power")
    light_power.add_argument("light")
    light_power.add_argument("value", choices=("on", "off"))
    light_brightness = sub.add_parser("light-brightness")
    light_brightness.add_argument("light")
    light_brightness.add_argument("value", type=int)
    light_colour = sub.add_parser("light-colour")
    light_colour.add_argument("light")
    light_colour.add_argument("hue", type=int)
    light_colour.add_argument("sat", type=int, nargs="?", default=220)
    ambient_start_p = sub.add_parser("ambient-start")
    ambient_start_p.add_argument("room")
    ambient_start_p.add_argument("--monitor", default="all")
    sub.add_parser("ambient-stop")
    lightshow_start_p = sub.add_parser("lightshow-start")
    lightshow_start_p.add_argument("room")
    lightshow_start_p.add_argument("--colors", required=True)
    sub.add_parser("lightshow-stop")
    sub.add_parser("monitors")
    args = parser.parse_args()
    if args.command == "status": result = snapshot()
    elif args.command == "pair": result = pair(args.ip) and snapshot()
    elif args.command == "power": result = set_room(args.room, {"on": args.value == "on"})
    elif args.command == "brightness": result = set_room(args.room, {"on": True, "bri": max(1, min(254, args.value))})
    elif args.command == "colour": result = set_room(args.room, {"on": True, "hue": args.hue % 65536, "sat": max(0, min(254, args.sat))})
    elif args.command == "scene": result = set_room(args.room, {"scene": args.scene})
    elif args.command == "light-power": result = set_light(args.light, {"on": args.value == "on"})
    elif args.command == "light-brightness": result = set_light(args.light, {"on": True, "bri": max(1, min(254, args.value))})
    elif args.command == "light-colour": result = set_light(args.light, {"on": True, "hue": args.hue % 65536, "sat": max(0, min(254, args.sat))})
    elif args.command == "ambient-start": result = ambient_start(args.room, args.monitor)
    elif args.command == "ambient-stop": result = stop_ambient()
    elif args.command == "lightshow-start": result = lightshow_start(args.room, args.colors)
    elif args.command == "lightshow-stop": result = stop_lightshow()
    else: result = monitors()
    emit(result)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, urllib.error.URLError, ValueError) as error:
        emit({"error": str(error)})
        sys.exit(1)
