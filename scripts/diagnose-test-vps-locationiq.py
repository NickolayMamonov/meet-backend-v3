#!/usr/bin/env python3
"""One fixed public fixture GET and, conditionally, one read-only geocoder GET."""

from contextlib import contextmanager
import fcntl
import http.client
import json
import math
import os
from pathlib import Path
import re
import resource
import signal
import sys
import time
import unicodedata
import urllib.parse

from test_vps_file_trust import Rejected, directory, private_file

STATE = Path("/var/lib/meet-test-vps-deploy")
MAX_BYTES = 1_048_576
MAX_KEY = 4096
FIXTURE_HOST = "api.whysoezzy.online"
PROVIDER_HOST = "eu1.locationiq.com"
EXTERNAL_HOST = "centicore-group.timepad.ru"
STRUCTURE = re.compile(r"(?<!\w)(?:стр\.?|строение)\s*[0-9]+[а-яa-z0-9/-]*", re.IGNORECASE)
INPUT_COMPONENTS = re.compile(
    r"(?P<road>.+?)\s+(?P<house>[0-9]+[а-яa-z0-9/-]*"
    r"(?:,\s*(?:стр\.?|строение)\s*[0-9]+[а-яa-z0-9/-]*)?)", re.IGNORECASE)


def deadline(_signal, _frame):
    raise Rejected("deadline")


@contextmanager
def phase_budget(until):
    remaining = until - time.monotonic()
    if remaining <= 0:
        raise Rejected("deadline")
    signal.setitimer(signal.ITIMER_REAL, min(15, remaining))
    try:
        yield
    finally:
        remaining = until - time.monotonic()
        signal.setitimer(signal.ITIMER_REAL, max(0, remaining))
        if remaining <= 0:
            raise Rejected("deadline")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Rejected("json_duplicate")
        result[key] = value
    return result


def parse_json(data):
    if len(data) > MAX_BYTES:
        raise Rejected("body_budget")
    text = data.decode("utf-8")
    # Bound nesting before the recursive JSON decoder allocates containers.
    depth, quoted, escaped = 0, False, False
    for char in text:
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char in "[{":
            depth += 1
            if depth > 16:
                raise Rejected("json_depth")
        elif char in "]}":
            depth -= 1
    def reject_constant(_):
        raise Rejected("json_constant")
    return json.loads(text, object_pairs_hook=unique_object,
                      parse_constant=reject_constant)


def get_json(host, path, until):
    with phase_budget(until):
        connection = http.client.HTTPSConnection(host, timeout=min(3, until-time.monotonic()))
        try:
            connection.connect()
            connection.sock.settimeout(min(3, max(0.001, until-time.monotonic())))
            connection.request("GET", path, headers={
                "Accept": "application/json", "Accept-Encoding": "identity"})
            response = connection.getresponse()
            if type(response.status) is not int or not 100 <= response.status <= 599:
                raise Rejected("http_status")
            if response.status != 200:
                return response.status, None
            if response.getheader("Content-Encoding", "identity").strip().lower() != "identity":
                raise Rejected("content_encoding")
            if response.getheader("Content-Type", "").split(";")[0].strip().lower() != "application/json":
                raise Rejected("content_type")
            return response.status, parse_json(response.read(MAX_BYTES + 1))
        finally:
            connection.close()


def key_value(raw):
    if not 0 < len(raw) <= MAX_KEY or any(c < 33 or c > 126 for c in raw):
        raise Rejected("invalid_key")
    return raw.decode("ascii")


def field(value, key):
    if not isinstance(value, dict) or key not in value:
        return "missing"
    v = value[key]
    if v is None:
        return "null"
    return {str: "string", bool: "boolean", int: "number", float: "number",
            dict: "object", list: "array"}.get(type(v), "other")


def point(latitude, longitude, *, strings=True):
    values = []
    for v, limit in ((latitude, 90), (longitude, 180)):
        if type(v) not in (int, float, str) or (isinstance(v, str) and (
                not strings or len(v) > 64 or not re.fullmatch(r"-?[0-9]+(?:\.[0-9]+)?", v))):
            return False
        try:
            number = float(v)
        except (ValueError, OverflowError):
            return False
        if not math.isfinite(number) or abs(number) > limit:
            return False
        values.append(number)
    return values != [0, 0]


def normalize(value):
    return unicodedata.normalize("NFKC", value).casefold()


def component(value, forbidden):
    if value is None:
        return {"value": None, "reason": "missing"}
    if not isinstance(value, str):
        return {"value": None, "reason": "wrong_type"}
    if not value or len(value) > 128:
        return {"value": None, "reason": "length"}
    normalized = normalize(value)
    if any(c in normalized for c in ("www", "http", "://", "@", "%", "?", "&", "=")):
        return {"value": None, "reason": "unsafe_text"}
    if any(not (unicodedata.category(c)[0] in "LN" or c in " .,-/()") for c in value):
        return {"value": None, "reason": "unsafe_text"}
    if any(normalize(s) in normalized for s in forbidden if s):
        return {"value": None, "reason": "reflection"}
    return {"value": value, "reason": "public_component"}


def components(address, forbidden):
    road = component(address.get("road"), forbidden)
    house = component(address.get("house_number"), forbidden)
    structure = {"value": None, "reason": "not_separately_identified"}
    if house["value"] is not None:
        matches = list(STRUCTURE.finditer(house["value"]))
        if len(matches) == 1 and matches[0].end() == len(house["value"]):
            structure = component(matches[0].group(), forbidden)
    return {"road": road, "house": house, "structure": structure}


def input_components(address, forbidden):
    match = INPUT_COMPONENTS.fullmatch(address)
    if match is None or any(c.isdigit() for c in match["road"]):
        return None
    return components({"road": match["road"], "house_number": match["house"]}, forbidden)


def comparison(left, right):
    evaluated = left is not None and right is not None
    return {"evaluated": evaluated, "matches": evaluated and left == right}


def enum_field(obj, name, allowed):
    value = obj.get(name)
    return {"type": field(obj, name),
            "value": value if isinstance(value, str) and value in allowed else "unknown"}


def result_summary(value, key, inputs, factual_address):
    if not isinstance(value, dict):
        raise Rejected("provider_shape")
    address = value.get("address")
    address = address if isinstance(address, dict) else {}
    quality = value.get("matchquality")
    quality = quality if isinstance(quality, dict) else {}
    forbidden = [key, urllib.parse.quote(key, safe="")]
    forbidden.extend(str(value[k]) for k in ("lat", "lon") if k in value and len(str(value[k])) >= 4)
    public = components(address, forbidden)
    comparisons = {
        k: comparison(inputs[k]["value"] if inputs else None, public[k]["value"])
        for k in ("road", "house", "structure")}
    reconstructed = None
    if public["road"]["value"] and public["house"]["value"]:
        reconstructed = public["road"]["value"] + " " + public["house"]["value"]
    return {
        "fields": {k: field(value, k) for k in ("lat", "lon", "address", "matchquality")},
        "addressFields": {k: field(address, k) for k in ("country_code", "city", "road", "house_number")},
        "coordinatesValidNonzero": point(value.get("lat"), value.get("lon")),
        "quality": {
            "code": enum_field(quality, "matchcode", {"exact", "fallback", "approximate"}),
            "type": enum_field(quality, "matchtype", {"point", "centroid", "interpolated"}),
            "level": enum_field(quality, "matchlevel", {"venue", "building", "house", "street", "city", "country"}),
        },
        "countryIsRu": isinstance(address.get("country_code"), str) and address["country_code"] == "ru",
        "cityIsMoscow": isinstance(address.get("city"), str) and address["city"].casefold() == "\u043c\u043e\u0441\u043a\u0432\u0430",
        "components": public, "comparisons": comparisons,
        "literalReconstruction": comparison(factual_address, reconstructed),
    }


def fixture_address(value):
    if (not isinstance(value, dict) or type(value.get("id")) is not int or value["id"] != 7
            or value.get("source") != "TIMEPAD" or value.get("isOnline") is not False):
        raise Rejected("fixture_identity")
    external = value.get("externalUrl")
    if not isinstance(external, str):
        raise Rejected("fixture_identity")
    parsed = urllib.parse.urlsplit(external)
    if (parsed.scheme != "https" or parsed.netloc != EXTERNAL_HOST
            or parsed.path not in ("/event/4178295", "/event/4178295/")
            or parsed.query or parsed.fragment):
        raise Rejected("fixture_identity")
    address = value.get("address")
    text = address.get("address") if isinstance(address, dict) else None
    if not isinstance(text, str) or not text.strip() or len(text) > 2048:
        raise Rejected("fixture_address")
    return " ".join(text.split()), address


def diagnose(raw, state=STATE, request=get_json, until=None):
    key = key_value(raw)
    until = time.monotonic() + 40 if until is None else until
    state_fd = lock_fd = -1
    report = {"schemaVersion": 1, "fixtureId": 7, "externalEventId": 4178295,
              "stage": "backend", "status": "rejected", "reason": "http_status"}
    try:
        state_fd = directory(state)
        lock_fd, _, _ = private_file(state_fd, ".deploy.lock", deployment_lock=True)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name in (".provider-transaction.current", ".smtp-transaction.current"):
            try:
                os.stat(name, dir_fd=state_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise Rejected("unresolved_transaction")
        if time.monotonic() >= until:
            raise Rejected("deadline")
        status, value = request(FIXTURE_HOST, "/meetings/7", until)
        report["backendHttp"] = status
        if status != 200:
            return report
        factual, address = fixture_address(value)
        if point(address.get("latitude"), address.get("longitude"), strings=False):
            return {**report, "status": "skipped", "reason": "already_has_coordinates"}
        inputs = input_components(factual, [key, urllib.parse.quote(key, safe="")])
        query = urllib.parse.urlencode({
            "key": key, "q": factual + ", \u041c\u043e\u0441\u043a\u0432\u0430, \u0420\u043e\u0441\u0441\u0438\u044f",
            "format": "json", "accept-language": "ru", "countrycodes": "ru",
            "addressdetails": "1", "normalizeaddress": "1", "normalizecity": "0",
            "matchquality": "1", "limit": "2", "dedupe": "0",
        }, quote_via=urllib.parse.quote)
        if time.monotonic() >= until:
            raise Rejected("deadline")
        report["stage"] = "locationiq"
        status, value = request(PROVIDER_HOST, "/v1/search?" + query, until)
        report["providerHttp"] = status
        if status != 200:
            return report
        if not isinstance(value, list) or len(value) > 2:
            raise Rejected("provider_shape")
        return {**report, "status": "observed", "reason": "diagnostic_only",
                "count": len(value), "inputComponents": inputs,
                "results": [result_summary(v, key, inputs, factual) for v in value]}
    finally:
        for fd in (lock_fd, state_fd):
            if fd >= 0:
                os.close(fd)


REASONS = frozenset({
    "deadline", "invalid_key", "json_duplicate", "json_depth", "json_constant", "body_budget", "http_status",
    "content_encoding", "content_type", "fixture_identity", "fixture_address",
    "provider_shape", "unresolved_transaction", "unsafe_path", "unsafe_directory",
    "unexpected_acl", "unsafe_private_file", "nonempty_deployment_lock", "file_budget",
    "file_changed", "root_no_arguments_required",
})


def main():
    signal.signal(signal.SIGALRM, deadline)
    signal.setitimer(signal.ITIMER_REAL, 40)
    until = time.monotonic() + 40
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        if os.geteuid() != 0 or len(sys.argv) != 1:
            raise Rejected("root_no_arguments_required")
        result = diagnose(sys.stdin.buffer.read(MAX_KEY+1), until=until)
        code = 0
    except Rejected as error:
        reason = error.args[0] if error.args and error.args[0] in REASONS else "diagnostic_failed"
        result = {"schemaVersion": 1, "fixtureId": 7, "externalEventId": 4178295, "stage": "diagnostic",
                  "status": "rejected", "reason": reason}
        code = 1
    except Exception:
        # This is the secret-bearing process boundary: never echo exception text.
        result = {"schemaVersion": 1, "fixtureId": 7, "externalEventId": 4178295, "stage": "diagnostic",
                  "status": "rejected", "reason": "diagnostic_failed"}
        code = 1
    try:
        output = json.dumps(result, ensure_ascii=True, separators=(",", ":"))
        if len(output.encode()) > 8192:
            output = '{"schemaVersion":1,"stage":"diagnostic","status":"rejected","reason":"output_budget"}'
            code = 1
        # Keep the whole deadline armed through stdout delivery as well.
        print(output, flush=True)
        return code
    except (Rejected, OSError):
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == "__main__":
    sys.exit(main())
