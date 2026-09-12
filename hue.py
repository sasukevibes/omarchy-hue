#!/usr/bin/env python3
"""Small, dependency-free Philips Hue v1 client for the Omarchy widget."""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

STATE = Path.home() / ".local/state/omarchy/hue.json"
TIMEOUT = 3

# Hue v1 group/light identifiers are always small decimal integers, and the
# bridge is always addressed by IPv4 on the local network. Both values flow
# straight into a request path/URL below, so they're validated up front
# rather than trusted as opaque strings.
ID_RE = re.compile(r"^[0-9]{1,8}$")
IPV4_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")


def valid_id(value):
    if not ID_RE.match(str(value)):
        raise RuntimeError("Invalid identifier")
    return str(value)


def valid_ip(value):
    if not IPV4_RE.match(str(value)) or any(int(part) > 255 for part in str(value).split(".")):
        raise RuntimeError("Invalid bridge address")
    return str(value)


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
        return {"paired": False, "bridges": bridges,
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
    return {"paired": True, "bridge": cfg.get("bridge_name", "Hue Bridge"), "rooms": rooms}


def set_room(room, payload):
    api(f"groups/{valid_id(room)}/action", "PUT", payload)
    return snapshot()


def set_light(light, payload):
    api(f"lights/{valid_id(light)}/state", "PUT", payload)
    return snapshot()


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
    args = parser.parse_args()
    if args.command == "status": result = snapshot()
    elif args.command == "pair": result = pair(args.ip) and snapshot()
    elif args.command == "power": result = set_room(args.room, {"on": args.value == "on"})
    elif args.command == "brightness": result = set_room(args.room, {"on": True, "bri": max(1, min(254, args.value))})
    elif args.command == "colour": result = set_room(args.room, {"on": True, "hue": args.hue % 65536, "sat": max(0, min(254, args.sat))})
    elif args.command == "scene": result = set_room(args.room, {"scene": args.scene})
    elif args.command == "light-power": result = set_light(args.light, {"on": args.value == "on"})
    elif args.command == "light-brightness": result = set_light(args.light, {"on": True, "bri": max(1, min(254, args.value))})
    else: result = set_light(args.light, {"on": True, "hue": args.hue % 65536, "sat": max(0, min(254, args.sat))})
    emit(result)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, urllib.error.URLError, ValueError) as error:
        emit({"error": str(error)})
        sys.exit(1)
