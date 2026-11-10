# ContextForge plugin: search-and-replace rules on tool results and rendered
# prompts, with rule groups scoped by the email's sender/subject. The logic
# lives in scoped_filter_core.py; this file only adapts it to the plugin
# framework, mirroring the stock regex_filter plugin's hooks.
import copy

from cpex.framework import (
    Plugin,
    PluginConfig,
    PluginContext,
    PromptPosthookPayload,
    PromptPosthookResult,
    ToolPostInvokePayload,
    ToolPostInvokeResult,
)

from .scoped_filter_core import ScopedFilter


class ScopedFilterPlugin(Plugin):
    def __init__(self, config: PluginConfig):
        super().__init__(config)
        # A bad rule raises here, so the gateway refuses to start rather than
        # running without it.
        self._filter = ScopedFilter(self._config.config or {})

    async def prompt_post_fetch(self, payload: PromptPosthookPayload, context: PluginContext) -> PromptPosthookResult:
        # A rendered prompt has no sender/subject: every group applies.
        if payload.result and payload.result.messages:
            result = copy.deepcopy(payload.result)
            for message in result.messages:
                if getattr(message.content, "text", None) is not None:
                    message.content.text = self._filter.filter_text(message.content.text)
            payload = payload.model_copy(update={"result": result})
        return PromptPosthookResult(modified_payload=payload)

    async def tool_post_invoke(self, payload: ToolPostInvokePayload, context: PluginContext) -> ToolPostInvokeResult:
        if payload.result:
            payload = payload.model_copy(update={"result": self._filter.filter_result(payload.result)})
        return ToolPostInvokeResult(modified_payload=payload)
