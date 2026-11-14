# ContextForge plugin: the rule layer. Search-and-replace rules (scoped by
# upstream server and by the email's sender/subject), then the generic
# detectors with stable pseudonyms, on tool results and rendered prompts; and
# the reverse on tool arguments: known pseudonyms are replaced by the
# originals before the call reaches the upstream server. The logic lives in
# the *_core.py modules; this file only adapts it to the plugin framework.
import copy
import logging

from cpex.framework import (
    Plugin,
    PluginConfig,
    PluginContext,
    PromptPosthookPayload,
    PromptPosthookResult,
    ToolPostInvokePayload,
    ToolPostInvokeResult,
    ToolPreInvokePayload,
    ToolPreInvokeResult,
)

from .pseudonym_core import Pseudonymizer, load_key, open_store, restore
from .scoped_filter_core import ScopedFilter

logger = logging.getLogger(__name__)


class ScopedFilterPlugin(Plugin):
    def __init__(self, config: PluginConfig):
        super().__init__(config)
        cfg = self._config.config or {}
        # A bad rule, a missing key or an unusable store raises here, so the
        # gateway refuses to start rather than running without them.
        self._store = open_store(cfg["store_path"], cfg.get("store_ttl_days", 180))
        self._p = Pseudonymizer(load_key(cfg["key_file"]), self._store)
        self._filter = ScopedFilter(cfg, self._p)

    def _done(self, counts):
        # Recorded before the result leaves, so any pseudonym the agent sees
        # can be resolved in its next call. A store error fails the call.
        self._p.flush()
        if counts:
            logger.info("ScopedFilter: detections by kind: %s", counts)

    async def tool_pre_invoke(self, payload: ToolPreInvokePayload, context: PluginContext) -> ToolPreInvokeResult:
        if payload.args:
            payload = payload.model_copy(update={"args": restore(payload.args, self._store)})
        return ToolPreInvokeResult(modified_payload=payload)

    async def prompt_post_fetch(self, payload: PromptPosthookPayload, context: PluginContext) -> PromptPosthookResult:
        # A rendered prompt has no sender/subject or server: every group applies.
        if payload.result and payload.result.messages:
            result = copy.deepcopy(payload.result)
            counts = {}
            for message in result.messages:
                if getattr(message.content, "text", None) is not None:
                    message.content.text = self._filter.filter_text(message.content.text, counts=counts)
            self._done(counts)
            payload = payload.model_copy(update={"result": result})
        return PromptPosthookResult(modified_payload=payload)

    async def tool_post_invoke(self, payload: ToolPostInvokePayload, context: PluginContext) -> ToolPostInvokeResult:
        if payload.result:
            # On tool calls the gateway sets server_id to the *upstream* MCP
            # server's id (v1.1.0, tool_service._apply_tool_payload_to_global_context),
            # not the virtual server's: per-server groups follow the upstream.
            server_id = getattr(context.global_context, "server_id", None)
            counts = {}
            result = self._filter.filter_result(payload.result, server_id, counts)
            self._done(counts)
            payload = payload.model_copy(update={"result": result})
        return ToolPostInvokeResult(modified_payload=payload)
