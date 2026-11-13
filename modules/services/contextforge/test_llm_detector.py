# Unit tests for the LLM detector, with a fake model and a fake Ollama HTTP
# server. Run by `nix flake check`. All data here is synthetic.
import http.server
import json
import threading
import time
import unittest

from llm_detector_core import LlmDetector, LlmError


class FakeModel:
    """Finds the given strings wherever they occur; records each request."""

    def __init__(self, *needles, kind="name"):
        self.needles = needles
        self.kind = kind
        self.requests = []

    def __call__(self, text):
        self.requests.append(text)
        return [(n, self.kind) for n in self.needles if n.casefold() in text.casefold()]


def emails(*bodies, sender="Shop <x@shop.example>"):
    return {"results": [{"id": f"M{i}", "from": [{"name": sender, "email": "[HASH:00]"}], "subject": "Hi", "preview": b} for i, b in enumerate(bodies)]}


def tool_result(obj):
    # What the gateway hands tool_post_invoke: JSON text block + structuredContent.
    return {"content": [{"type": "text", "text": json.dumps(obj)}], "structuredContent": obj, "isError": False}


class Units(unittest.TestCase):
    def test_one_request_per_email_not_the_raw_json(self):
        model = FakeModel()
        LlmDetector({}, ask=model).scan(tool_result(emails("first body", "second body")))
        self.assertEqual(len(model.requests), 2)
        for req in model.requests:
            self.assertNotIn("{", req)
            self.assertNotIn("M0", req)  # ids are not sent
        self.assertIn("preview: first body", model.requests[0])
        self.assertIn("from.name: Shop <x@shop.example>", model.requests[0])

    def test_duplicate_copy_of_an_email_is_asked_once(self):
        # content[0].text and structuredContent carry the same emails.
        model = FakeModel()
        LlmDetector({}, ask=model).scan(tool_result(emails("same")))
        self.assertEqual(len(model.requests), 1)

    def test_text_outside_emails_is_one_unit(self):
        model = FakeModel()
        LlmDetector({}, ask=model).scan({"content": [{"type": "text", "text": "Note for Kari Nordmann"}], "isError": False})
        self.assertEqual(model.requests, ["content.text: Note for Kari Nordmann"])

    def test_long_unit_is_split_not_truncated(self):
        model = FakeModel("Kari Nordmann")
        body = ("word " * 50 + "\n") * 40 + "signed Kari Nordmann"
        out = LlmDetector({"max_chars": 600}, ask=model).scan({"from": "a", "subject": "s", "body": body})
        self.assertGreater(len(model.requests), 1)
        self.assertTrue(all(len(r) <= 600 for r in model.requests))
        self.assertNotIn("Kari", out["body"])


class Masking(unittest.TestCase):
    def test_finding_masked_consistently(self):
        d = LlmDetector({}, ask=FakeModel("Kari Nordmann"))
        out = d.scan(tool_result(emails("Hi Kari Nordmann", "KARI NORDMANN again")))
        res = out["structuredContent"]["results"]
        self.assertNotIn("Kari", json.dumps(out))
        self.assertRegex(res[0]["preview"], r"^Hi \[PII:[0-9a-f]{12}\]$")
        self.assertEqual(res[0]["preview"][3:], res[1]["preview"][:-6])
        self.assertEqual(json.loads(out["content"][0]["text"]), out["structuredContent"])

    def test_finding_only_masked_in_its_own_email(self):
        # Found in email 0 only; a word equal to it elsewhere stays.
        class OnlyFirst(FakeModel):
            def __call__(self, text):
                return [("Bergen", "address")] if "Storgata" in text else []

        out = LlmDetector({}, ask=OnlyFirst()).scan(emails("Storgata 1, Bergen", "Flight to Bergen"))
        self.assertNotIn("Bergen", out["results"][0]["preview"])
        self.assertEqual(out["results"][1]["preview"], "Flight to Bergen")

    def test_whole_words_only(self):
        out = LlmDetector({}, ask=FakeModel("Ann")).scan({"from": "a", "subject": "s", "body": "Ann sent the Annual report"})
        self.assertRegex(out["body"], r"^\[PII:[0-9a-f]+\] sent the Annual report$")

    def test_ids_and_structure_untouched(self):
        out = LlmDetector({}, ask=FakeModel("M0", "Hi")).scan(emails("x"))
        self.assertEqual(out["results"][0]["id"], "M0")

    def test_unusable_findings_ignored(self):
        class Noisy(FakeModel):
            def __call__(self, text):
                return [("ab", "other"), ("[HASH:00]", "email"), ("[ORDER]", "id"), ("Not in text", "name"), ("preview", "other"), ("...", "other")]

        body = {"from": "a", "subject": "s", "preview": "ab [HASH:00] [ORDER]"}
        self.assertEqual(LlmDetector({}, ask=Noisy()).scan(dict(body)), body)

    def test_longest_finding_first(self):
        out = LlmDetector({}, ask=FakeModel("Kari", "Kari Nordmann")).scan({"from": "a", "subject": "s", "b": "Kari Nordmann"})
        self.assertRegex(out["b"], r"^\[PII:[0-9a-f]+\]$")

    def test_plain_string_result(self):
        out = LlmDetector({}, ask=FakeModel("Kari")).scan("From: x\nHi Kari")
        self.assertRegex(out, r"Hi \[PII:")


class FailClosed(unittest.TestCase):
    def test_model_error_propagates(self):
        def broken(text):
            raise LlmError("down")

        with self.assertRaises(LlmError):
            LlmDetector({}, ask=broken).scan(emails("x"))

    def test_deadline_stops_further_requests(self):
        model = FakeModel()
        with self.assertRaisesRegex(LlmError, "out of time"):
            LlmDetector({}, ask=model).scan(emails("a", "b"), deadline=time.monotonic() - 1)
        self.assertEqual(model.requests, [])


class FakeOllama(http.server.BaseHTTPRequestHandler):
    reply = None
    seen = []

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeOllama.seen.append((self.path, body))
        if FakeOllama.reply is None:
            time.sleep(2)
            return
        data = json.dumps(FakeOllama.reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class OllamaClient(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        FakeOllama.seen = []

    def detector(self, **extra):
        return LlmDetector({"url": self.url, "model": "m:1", "request_timeout": 1, **extra})

    def answer(self, content):
        FakeOllama.reply = {"message": {"role": "assistant", "content": content}, "done": True}

    def test_request_and_answer(self):
        self.answer(json.dumps({"findings": [{"text": "Kari", "kind": "name"}]}))
        out = self.detector(num_ctx=4096, keep_alive="5m").scan({"from": "a", "subject": "s", "b": "Hi Kari"})
        self.assertRegex(out["b"], r"^Hi \[PII:")
        path, body = FakeOllama.seen[0]
        self.assertEqual(path, "/api/chat")
        self.assertEqual(body["model"], "m:1")
        self.assertFalse(body["stream"])
        self.assertEqual(body["options"]["num_ctx"], 4096)
        self.assertEqual(body["keep_alive"], "5m")
        self.assertEqual(body["format"]["required"], ["findings"])
        self.assertIn("b: Hi Kari", body["messages"][1]["content"])

    def test_malformed_answers_fail(self):
        for content in ("not json", json.dumps({"other": 1}), json.dumps({"findings": [{"kind": "name"}]})):
            with self.subTest(content=content):
                self.answer(content)
                with self.assertRaises(LlmError):
                    self.detector().scan({"from": "a", "subject": "s", "b": "x"})

    def test_timeout_fails(self):
        FakeOllama.reply = None
        with self.assertRaises(LlmError):
            self.detector().scan({"from": "a", "subject": "s", "b": "x"})

    def test_unreachable_fails(self):
        d = LlmDetector({"url": "http://127.0.0.1:9", "model": "m", "request_timeout": 1})
        with self.assertRaises(LlmError):
            d.scan({"from": "a", "subject": "s", "b": "x"})


if __name__ == "__main__":
    unittest.main()
