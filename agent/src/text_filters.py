"""Streaming text filters for the voice pipeline.

MiniMax-M3 is a reasoning model: it emits its chain-of-thought inside a
`<think>...</think>` block in the content channel. The SDK strips that block on
text-only deltas, but when the closing `</think>` arrives in the same chunk as a
tool call the reasoning tail leaks into the spoken reply. Rather than disabling
thinking outright (which also removes the reasoning that helps code judgments),
we keep thinking on and strip the block at the TTS boundary with
`strip_think_stream`, so reasoning never reaches the speaker.
"""

from __future__ import annotations

from collections.abc import AsyncIterable, AsyncIterator

THINK_OPEN = "<think>"
THINK_CLOSE = "</think>"


def _partial_suffix_len(buf: str, tag: str) -> int:
    """Length of the longest suffix of `buf` that is a proper prefix of `tag`.

    Used to hold back the tail of a buffer that might be the start of a tag
    split across streaming chunks (e.g. buf ends with "<thi" for "<think>"), so
    a partial tag is never emitted as visible text or mistaken for content.
    """
    for k in range(min(len(buf), len(tag) - 1), 0, -1):
        if buf.endswith(tag[:k]):
            return k
    return 0


async def strip_think_stream(text: AsyncIterable[str]) -> AsyncIterator[str]:
    """Yield `text` with every `<think>...</think>` span removed.

    Streaming-safe: tags may straddle chunk boundaries, and a single chunk may
    open and/or close multiple spans. Text outside think spans passes through
    byte-for-byte; text inside (and the tags themselves) is dropped. An unclosed
    `<think>` at end-of-stream drops its trailing text (it was never answer
    content). Idempotent on input that has no tags.
    """
    buf = ""
    inside = False
    async for chunk in text:
        if not chunk:
            continue
        buf += chunk
        while True:
            if not inside:
                idx = buf.find(THINK_OPEN)
                if idx == -1:
                    # No open tag: emit everything except a possible partial-tag
                    # tail, which we hold for the next chunk.
                    hold = _partial_suffix_len(buf, THINK_OPEN)
                    emit = buf[: len(buf) - hold]
                    if emit:
                        yield emit
                    buf = buf[len(buf) - hold :]
                    break
                if idx > 0:
                    yield buf[:idx]
                buf = buf[idx + len(THINK_OPEN) :]
                inside = True
            else:
                idx = buf.find(THINK_CLOSE)
                if idx == -1:
                    # Inside a span: drop content, but keep a possible
                    # partial-close tail so a split `</think>` is still matched.
                    hold = _partial_suffix_len(buf, THINK_CLOSE)
                    buf = buf[len(buf) - hold :] if hold else ""
                    break
                buf = buf[idx + len(THINK_CLOSE) :]
                inside = False
    # Flush any trailing text that is outside a think span.
    if buf and not inside:
        yield buf
