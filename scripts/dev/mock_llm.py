#!/usr/bin/env python3
"""Deterministic mock of an OpenAI-compatible endpoint for pipeline e2e tests.

Understands the RetainPDF translation protocols (verified against
retainpdf-pipeline 4.2.6 request shapes):

  * domain inference   -- strict JSON {"domain","summary","translation_guidance"}
  * tagged batch       -- ``<<<ITEM item_id=ID>>> ... <<<END>>>`` blocks
  * single item plain  -- source between 【当前原文开始】/【当前原文结束】, plain reply
  * classification     -- ``no-trans:`` (translate everything)

Every reply is Chinese-only (keeps the English-residue validator quiet) and
padded towards the source length so short-translation retries don't fire.

Usage: ``python3 scripts/dev/mock_llm.py [--port 18901] [--log DIR]``
"""
from __future__ import annotations

import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STUB = "这是智阅端到端测试使用的模拟译文，仅用于验证整条翻译与排版链路。"

ITEM_BLOCK_RE = re.compile(r"<<<ITEM item_id=([^>\s]+)>>>")


def _padded_translation(source: str, index: int) -> str:
    """Chinese-only stub roughly matching the source's length."""
    target_len = max(12, int(len(source) * 0.6))
    text = ""
    while len(text) < target_len:
        text += STUB
    return f"【模拟译文{index}】{text}"


def _extract_single_source(user: str) -> str:
    m = re.search(r"【当前原文开始】(.*?)【当前原文结束】", user, re.S)
    return (m.group(1) if m else "").strip()


def _extract_batch_items(user: str) -> list[tuple[str, str]]:
    """Parses ``原文 <id>:`` blocks; returns [(item_id, source_text)]."""
    items: list[tuple[str, str]] = []
    matches = list(re.finditer(r"原文\s+([^\s:]+)\s*:\s*\n", user))
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(user)
        items.append((m.group(1), user[start:end].strip()))
    return items


def build_reply(body: dict) -> str:
    messages = body.get("messages", []) or []
    system = "\n".join(m.get("content", "") for m in messages if m.get("role") == "system")
    user = "\n".join(m.get("content", "") for m in messages if m.get("role") == "user")

    if "判断文档所属" in system:
        return json.dumps(
            {
                "domain": "测试领域",
                "summary": "用于端到端测试的英文科技短文。",
                "translation_guidance": "保持术语一致；数学表达式主动用 $...$ 包裹；保留英文缩写。",
            },
            ensure_ascii=False,
        )

    if "是否覆盖原文" in system:
        return "no-trans:"

    if ITEM_BLOCK_RE.search(user) or "原文 " in user and "<<<ITEM" in user:
        items = _extract_batch_items(user)
        if items:
            parts = []
            for i, (item_id, source) in enumerate(items, start=1):
                parts.append(f"<<<ITEM item_id={item_id}>>>\n{_padded_translation(source, i)}\n<<<END>>>")
            return "\n".join(parts)

    source = _extract_single_source(user)
    if source:
        return _padded_translation(source, 1)

    # Unknown protocol: an explicit no-trans keeps classifiers happy and is
    # a safe default for anything else.
    return "no-trans:"


class Handler(BaseHTTPRequestHandler):
    log_dir: str | None = None
    delay = 0.0
    count = 0

    def do_POST(self):  # noqa: N802 (stdlib naming)
        if Handler.delay:
            time.sleep(Handler.delay)
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw)
        except Exception:
            body = {}
        Handler.count += 1
        reply = build_reply(body if isinstance(body, dict) else {})
        if self.log_dir:
            import os

            os.makedirs(self.log_dir, exist_ok=True)
            with open(os.path.join(self.log_dir, f"req_{Handler.count:03d}.json"), "w", encoding="utf-8") as f:
                json.dump({"body": body, "reply": reply}, f, ensure_ascii=False, indent=1)
        import os as _os

        if _os.environ.get("MOCK_LLM_VERBOSE"):
            sys_prompt = ""
            for m in (body.get("messages") or []):
                if m.get("role") == "system":
                    sys_prompt = (m.get("content") or "")[:60]
            print(f"[mock] #{Handler.count} sys={sys_prompt!r}", flush=True)
        payload = {
            "id": f"mock-{Handler.count}",
            "object": "chat.completion",
            "model": body.get("model", "mock") if isinstance(body, dict) else "mock",
            "choices": [
                {
                    "index": 0,
                    "message": {"role": "assistant", "content": reply},
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2},
        }
        out = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *args):  # silence
        pass


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18901)
    parser.add_argument("--log", default="")
    parser.add_argument("--delay", type=float, default=0.0,
                        help="seconds to sleep before each reply (cancel tests)")
    args = parser.parse_args()
    Handler.log_dir = args.log or None
    Handler.delay = args.delay
    print(f"mock llm listening on 127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()