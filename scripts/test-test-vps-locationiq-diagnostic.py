#!/usr/bin/env python3
"""Hermetic Linux/root diagnostic tests. No real HTTPS, keys, Docker or VPS."""

import copy
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

# Apply before dynamic imports and propagate to isolated Python subprocess tests.
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

SPEC = importlib.util.spec_from_file_location(
    "locationiq_diagnostic", Path(__file__).with_name("diagnose-test-vps-locationiq.py"))
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)
KEY = b"FAKE-DIAGNOSTIC-KEY-not-secret-123"
FACTUAL = "Test Street 1, \u0441\u0442\u0440 1"
FIXTURE = {"id": 7, "source": "TIMEPAD", "isOnline": False,
           "externalUrl": "https://centicore-group.timepad.ru/event/4178295/",
           "address": {"address": FACTUAL, "latitude": 0, "longitude": 0},
           "title": "PRIVATE-PROSE-SENTINEL", "participants": ["PRIVATE-USER-SENTINEL"]}
RESULT = {"lat": "55.234567891", "lon": "37.123456789",
          "display_name": "PRIVATE-PROVIDER-PROSE",
          "address": {"country_code": "ru", "city": "\u043c\u043e\u0441\u043a\u0432\u0430",
                      "road": "Test Street", "house_number": "1, \u0441\u0442\u0440 1"}}


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir="/root")
        self.root = Path(self.tmp.name)
        self.state = self.root / "state"
        self.state.mkdir(mode=0o700)
        self.lock = self.state / ".deploy.lock"
        self.lock.write_bytes(b"")
        self.lock.chmod(0o644)
        self.env = self.root / ".env.production"
        self.env.write_bytes(b"PRIVATE-ENV-DO-NOT-OPEN")
        self.request = Mock(side_effect=[(200, copy.deepcopy(FIXTURE)), (200, [copy.deepcopy(RESULT)])])

    def tearDown(self):
        self.tmp.cleanup()

    def diagnose(self, raw=KEY):
        return tool.diagnose(raw, self.state, self.request)

    def test_two_fixed_gets_no_state_writes_or_sensitive_output(self):
        before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (self.env, self.lock)}
        result = self.diagnose()
        self.assertEqual(result["status"], "observed")
        self.assertEqual(self.request.call_count, 2)
        host, path, _ = self.request.call_args_list[0].args
        self.assertEqual((host, path), ("api.whysoezzy.online", "/meetings/7"))
        host, path, _ = self.request.call_args_list[1].args
        self.assertEqual(host, "eu1.locationiq.com")
        self.assertTrue(path.startswith("/v1/search?"))
        query = tool.urllib.parse.parse_qs(tool.urllib.parse.urlsplit(path).query)
        self.assertEqual(query["key"], [KEY.decode()])
        self.assertEqual(query["q"], [FACTUAL + ", \u041c\u043e\u0441\u043a\u0432\u0430, \u0420\u043e\u0441\u0441\u0438\u044f"])
        self.assertEqual(query["limit"], ["2"])
        self.assertEqual(query["matchquality"], ["1"])
        output = json.dumps(result, ensure_ascii=False)
        for secret in (KEY.decode(), RESULT["lat"], RESULT["lon"], FACTUAL,
                       "PRIVATE-PROSE", "PRIVATE-USER", "PRIVATE-PROVIDER", "PRIVATE-ENV"):
            self.assertNotIn(secret, output)
        self.assertTrue(result["results"][0]["coordinatesValidNonzero"])
        self.assertEqual(result["results"][0]["quality"]["code"]["value"], "unknown")
        self.assertTrue(result["results"][0]["comparisons"]["structure"]["matches"])
        for p, (data, modified) in before.items():
            self.assertEqual((p.read_bytes(), p.stat().st_mtime_ns), (data, modified))
        self.assertEqual(sorted(x.name for x in self.state.iterdir()), [".deploy.lock"])

    def test_invalid_keys_fail_before_any_get(self):
        for key in (b"", b"x"*4097, b" abc", b"a b", b"abc\n", b"\xff", b"\x00"):
            with self.subTest(key_size=len(key)), self.assertRaises(tool.Rejected):
                self.diagnose(key)
        self.request.assert_not_called()

    def test_wrong_fixture_never_calls_geocoder(self):
        for field, value in (("id", 8), ("id", True), ("source", "MANUAL"),
                             ("isOnline", True), ("isOnline", 0), ("externalUrl", None),
                             ("address", {"address": ""})):
            fixture = copy.deepcopy(FIXTURE)
            fixture[field] = value
            request = Mock(return_value=(200, fixture))
            with self.subTest(field=field, value=value), self.assertRaises(tool.Rejected):
                tool.diagnose(KEY, self.state, request)
            self.assertEqual(request.call_count, 1)
        for url in ("http://centicore-group.timepad.ru/event/4178295/",
                    "https://centicore-group.timepad.ru:443/event/4178295/",
                    "https://user@centicore-group.timepad.ru/event/4178295/",
                    "https://centicore-group.timepad.ru/event/4178295/?x=1",
                    "https://centicore-group.timepad.ru/event/4178295/#x",
                    "https://evil.invalid/event/4178295/"):
            fixture = {**FIXTURE, "externalUrl": url}
            request = Mock(return_value=(200, fixture))
            with self.subTest(url=url), self.assertRaises(tool.Rejected):
                tool.diagnose(KEY, self.state, request)
            self.assertEqual(request.call_count, 1)

    def test_missing_unexposed_external_id_is_not_required(self):
        self.assertNotIn("sourceExternalId", FIXTURE)
        self.assertEqual(self.diagnose()["status"], "observed")

    def test_already_has_coordinates_skips_geocoder(self):
        fixture = copy.deepcopy(FIXTURE)
        fixture["address"].update(latitude=55.1, longitude=37.2)
        request = Mock(return_value=(200, fixture))
        self.assertEqual(tool.diagnose(KEY, self.state, request)["reason"], "already_has_coordinates")
        self.assertEqual(request.call_count, 1)

    def test_absent_or_invalid_point_allows_only_one_diagnostic(self):
        for point in ({}, {"latitude": None}, {"latitude": float("nan"), "longitude": 37},
                      {"latitude": 91, "longitude": 37}, {"latitude": True, "longitude": 37}):
            fixture = copy.deepcopy(FIXTURE)
            fixture["address"] = {"address": FACTUAL, **point}
            request = Mock(side_effect=[(200, fixture), (200, [])])
            self.assertEqual(tool.diagnose(KEY, self.state, request)["count"], 0)
            self.assertEqual(request.call_count, 2)

    def test_http_errors_redirects_and_transport_errors_are_not_retried(self):
        for status in (301, 302, 403, 429, 500):
            request = Mock(return_value=(status, None))
            self.assertEqual(tool.diagnose(KEY, self.state, request)["backendHttp"], status)
            self.assertEqual(request.call_count, 1)
            request = Mock(side_effect=[(200, FIXTURE), (status, None)])
            self.assertEqual(tool.diagnose(KEY, self.state, request)["providerHttp"], status)
            self.assertEqual(request.call_count, 2)
        request = Mock(side_effect=EOFError("PRIVATE-ERROR-SENTINEL"))
        with self.assertRaises(EOFError):
            tool.diagnose(KEY, self.state, request)
        self.assertEqual(request.call_count, 1)

    def test_pending_busy_and_unsafe_locks_never_get(self):
        for name in (".provider-transaction.current", ".smtp-transaction.current"):
            pointer = self.state / name
            pointer.symlink_to(self.root / "missing")
            with self.assertRaises(tool.Rejected):
                self.diagnose()
            pointer.unlink()
        with self.lock.open("rb") as f:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.diagnose()
        self.lock.write_bytes(b"not-empty")
        with self.assertRaises(tool.Rejected):
            self.diagnose()
        self.lock.write_bytes(b"")
        self.lock.chmod(0o666)
        with self.assertRaises(tool.Rejected):
            self.diagnose()
        self.lock.chmod(0o600)
        alias = self.state / "hardlink"
        os.link(self.lock, alias)
        with self.assertRaises(tool.Rejected):
            self.diagnose()
        alias.unlink()
        self.lock.unlink()
        self.lock.symlink_to(self.env)
        with self.assertRaises(OSError):
            self.diagnose()
        self.request.assert_not_called()

    def test_acl_and_ownership_rejected_before_get(self):
        with patch.object(tool.os, "listxattr", return_value=["system.posix_acl_access"]), \
                self.assertRaises(tool.Rejected):
            self.diagnose()
        os.chown(self.lock, 1, 0)
        with self.assertRaises(tool.Rejected):
            self.diagnose()
        self.request.assert_not_called()

    def test_missing_coarse_and_unknown_quality_still_observed(self):
        for quality in (None, "coarse", {}, {"matchcode": "fallback", "matchtype": "centroid"},
                        {"matchcode": "approximate", "matchtype": "interpolated", "matchlevel": "street"},
                        {"matchcode": "PRIVATE-QUALITY", "PRIVATE-DYNAMIC-FIELD": KEY.decode()}):
            value = {**RESULT, "matchquality": quality}
            request = Mock(side_effect=[(200, FIXTURE), (200, [value])])
            result = tool.diagnose(KEY, self.state, request)
            self.assertEqual(result["status"], "observed")
            self.assertNotIn("PRIVATE-", json.dumps(result))
            self.assertNotIn("PASS", json.dumps(result))

    def test_components_unambiguous_only_and_no_structure_fabrication(self):
        self.assertIsNone(tool.input_components("Ambiguous road without number", [KEY.decode()]))
        public = tool.components({"road": "Test Street", "house_number": "1"}, [KEY.decode()])
        self.assertIsNone(public["structure"]["value"])
        self.assertFalse(tool.comparison(None, "1")["evaluated"])
        self.assertFalse(tool.comparison(None, "1")["matches"])

    def test_component_filter_limits_unicode_and_reflections(self):
        self.assertEqual(tool.component("\u0410"*128, [KEY.decode()])["value"], "\u0410"*128)
        for text in ("\u0410"*129, "x\nx", "x\u202ex", "https://evil.invalid",
                     "www.example", "x@y", "<script>", "a%20b", KEY.decode().lower(),
                     tool.urllib.parse.quote(KEY.decode(), safe=""), "55.234567891"):
            with self.subTest(text=text):
                forbidden = [KEY.decode(), "55.234567891"]
                self.assertIsNone(tool.component(text, forbidden)["value"])
        self.assertIsNone(tool.component(123, [KEY.decode()])["value"])
        self.assertIsNone(tool.component("\uff26\uff21\uff2b\uff25-DIAGNOSTIC-KEY-not-secret-123", [KEY.decode()])["value"])
        value = {**RESULT, "address": {"road": KEY.decode(), "house_number": "1"}}
        summary = tool.result_summary(value, KEY.decode(), None, FACTUAL)
        self.assertIsNone(summary["components"]["road"]["value"])
        self.assertEqual(summary["fields"]["lat"], "string")

    def test_more_than_two_results_is_protocol_failure(self):
        self.request.side_effect = [(200, FIXTURE), (200, [RESULT]*3)]
        with self.assertRaisesRegex(tool.Rejected, "provider_shape"):
            self.diagnose()

    def test_state_directory_symlink_or_writable_ancestor_never_get(self):
        alias = self.root / "alias"
        alias.symlink_to(self.state, target_is_directory=True)
        with self.assertRaises(OSError):
            tool.diagnose(KEY, alias, self.request)
        self.state.chmod(0o777)
        with self.assertRaises(tool.Rejected):
            self.diagnose()
        self.request.assert_not_called()

    def test_no_second_get_after_backend_or_whole_deadline(self):
        def expired_backend(*_):
            raise tool.Rejected("deadline")
        request = Mock(side_effect=expired_backend)
        with self.assertRaisesRegex(tool.Rejected, "deadline"):
            tool.diagnose(KEY, self.state, request)
        self.assertEqual(request.call_count, 1)
        request = Mock(return_value=(200, FIXTURE))
        with self.assertRaisesRegex(tool.Rejected, "deadline"):
            tool.diagnose(KEY, self.state, request, until=time.monotonic()-1)
        self.assertEqual(request.call_count, 0)


class TransportTests(unittest.TestCase):
    def response(self, status=200, data=b"{}", headers=None):
        result = Mock(status=status)
        result.read.return_value = data
        headers = headers or {"Content-Type": "application/json"}
        result.getheader.side_effect = lambda k, default=None: headers.get(k, default)
        return result

    def test_strict_https_fixed_pattern_bounded_read_and_close(self):
        connection = Mock()
        connection.getresponse.return_value = self.response()
        with patch.object(tool.http.client, "HTTPSConnection", return_value=connection) as factory:
            self.assertEqual(tool.get_json("fixed.invalid", "/fixed", time.monotonic()+40), (200, {}))
        self.assertEqual(factory.call_args.args, ("fixed.invalid",))
        self.assertNotIn("context", factory.call_args.kwargs)
        self.assertLessEqual(factory.call_args.kwargs["timeout"], 3)
        connection.request.assert_called_once_with("GET", "/fixed", headers={
            "Accept": "application/json", "Accept-Encoding": "identity"})
        connection.getresponse.return_value.read.assert_called_once_with(tool.MAX_BYTES+1)
        connection.close.assert_called_once()
        signal.setitimer(signal.ITIMER_REAL, 0)

    def test_content_shape_and_json_limits(self):
        for raw in (b'{"x":1,"x":2}', b"["*17+b"]"*17, b'NaN',
                    b"x"*(tool.MAX_BYTES+1), b'{"oops"', b"\xff"):
            with self.subTest(size=len(raw)), self.assertRaises((tool.Rejected, ValueError)):
                tool.parse_json(raw)
        for headers in ({"Content-Type": "text/html"},
                        {"Content-Type": "application/json", "Content-Encoding": "gzip"}):
            connection = Mock()
            connection.getresponse.return_value = self.response(headers=headers)
            with patch.object(tool.http.client, "HTTPSConnection", return_value=connection), \
                    self.assertRaises(tool.Rejected):
                tool.get_json("fixed.invalid", "/fixed", time.monotonic()+40)
            signal.setitimer(signal.ITIMER_REAL, 0)

    def test_total_phase_deadline_includes_dns_headers_and_body(self):
        previous = signal.signal(signal.SIGALRM, tool.deadline)
        try:
            for blocked in ("connect", "getresponse", "read"):
                connection = Mock()
                response = self.response()
                connection.getresponse.return_value = response
                target = response.read if blocked == "read" else getattr(connection, blocked)
                target.side_effect = lambda *a, **k: time.sleep(1)
                with self.subTest(blocked=blocked), \
                        patch.object(tool.http.client, "HTTPSConnection", return_value=connection), \
                        self.assertRaisesRegex(tool.Rejected, "deadline"):
                    tool.get_json("fixed.invalid", "/fixed", time.monotonic()+0.03)
                signal.setitimer(signal.ITIMER_REAL, 0)
                connection.close.assert_called_once()
        finally:
            signal.signal(signal.SIGALRM, previous)

    def test_main_sanitizes_errors_and_output_budget(self):
        for error in (tool.Rejected("PRIVATE-ERROR-KEY"), OSError("PRIVATE-ERROR-KEY"),
                      ValueError("PRIVATE-ERROR-KEY")):
            with patch.object(tool.sys, "argv", ["diagnose"]), \
                    patch.object(tool.sys, "stdin", Mock(buffer=io.BytesIO(KEY))), \
                    patch.object(tool, "diagnose", side_effect=error), \
                    patch.object(tool.sys, "stdout", new_callable=io.StringIO) as stdout:
                self.assertEqual(tool.main(), 1)
                self.assertNotIn("PRIVATE", stdout.getvalue())
                self.assertEqual(len(stdout.getvalue().splitlines()), 1)
        with patch.object(tool.sys, "argv", ["diagnose"]), \
                patch.object(tool.sys, "stdin", Mock(buffer=io.BytesIO(KEY))), \
                patch.object(tool, "diagnose", return_value={"huge": "x"*9000}), \
                patch.object(tool.sys, "stdout", new_callable=io.StringIO) as stdout:
            self.assertEqual(tool.main(), 1)
            self.assertLess(len(stdout.getvalue().encode()), 8192)
            self.assertNotIn("huge", stdout.getvalue())

    def test_stalled_stdin_and_stdout_terminate_without_traceback(self):
        helper = str(Path(__file__).with_name("diagnose-test-vps-locationiq.py"))
        # Shorten only the initial timer in an isolated mock process, not production.
        for phase in ("stdin", "stdout"):
            wrapper = """
import importlib.util, io, signal, sys, time
spec=importlib.util.spec_from_file_location('diagnostic',sys.argv[1])
tool=importlib.util.module_from_spec(spec); spec.loader.exec_module(tool)
timer=signal.setitimer
tool.signal.setitimer=lambda which, delay: timer(which,min(delay,0.03))
class Block:
 def read(self,*args): time.sleep(5)
 def write(self,*args): time.sleep(5)
 def flush(self): pass
if sys.argv[2]=='stdin':
 tool.sys.stdin=type('Input',(),{'buffer':Block()})()
else:
 tool.sys.stdin=type('Input',(),{'buffer':io.BytesIO(b'fake-key')})()
 tool.diagnose=lambda *a,**kw: {'schemaVersion':1,'status':'observed'}
 tool.sys.stdout=Block()
tool.sys.argv=['diagnostic']
raise SystemExit(tool.main())
"""
            started = time.monotonic()
            result = subprocess.run(
                [sys.executable, "-c", wrapper, helper, phase],
                env={**os.environ, "PYTHONPATH": str(Path(helper).parent)},
                capture_output=True, timeout=2,
            )
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertNotIn(b"Traceback", result.stderr)
            self.assertLess(time.monotonic()-started, 2)


if __name__ == "__main__":
    unittest.main()
