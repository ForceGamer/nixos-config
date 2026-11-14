# ContextForge plugin: a local LLM as a safety net behind the rule layer.
# The logic lives in llm_detector_core.py; this file only adapts it to the
# plugin framework. It runs on every tool except those in `exclude_tools`
# (homelab.contextforge.llm.excludeTools).
import asyncio
import time

from cpex.framework import (
    Plugin,
    PluginConfig,
    PluginContext,
    ToolPostInvokePayload,
    ToolPostInvokeResult,
)

from .llm_detector_core import LlmDetector
from .pseudonym_core import Pseudonymizer, load_key, open_store


class LlmDetectorPlugin(Plugin):
    def __init__(self, config: PluginConfig):
        super().__init__(config)
        cfg = self._config.config or {}
        # Same key and store as the rule layer: a value it missed gets the
        # same kind of stable, reversible pseudonym.
        store = open_store(cfg["store_path"], cfg.get("store_ttl_days", 180))
        self._p = Pseudonymizer(load_key(cfg["key_file"]), store)
        self._detector = LlmDetector(cfg, self._p)
        # Kept below the framework's plugin_timeout, so the worker thread
        # stops sending requests once the call has failed anyway.
        self._budget = float(cfg.get("budget_seconds", 280))

    async def tool_post_invoke(self, payload: ToolPostInvokePayload, context: PluginContext) -> ToolPostInvokeResult:
        if payload.result and not self._detector.skips(payload.name):
            deadline = time.monotonic() + self._budget
            # In a thread: one gunicorn worker serves every request, and
            # urllib would block it for as long as the model takes.
            result = await asyncio.to_thread(self._detector.scan, payload.result, deadline)
            self._p.flush()
            payload = payload.model_copy(update={"result": result})
        return ToolPostInvokeResult(modified_payload=payload)
