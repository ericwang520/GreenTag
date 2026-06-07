import pytest

from text_filters import strip_think_stream


async def _aiter(chunks):
    for c in chunks:
        yield c


async def _collect(chunks) -> str:
    return "".join([c async for c in strip_think_stream(_aiter(chunks))])


@pytest.mark.asyncio
async def test_passthrough_without_tags() -> None:
    assert await _collect(["Studs are ", "16 inches ", "on center."]) == (
        "Studs are 16 inches on center."
    )


@pytest.mark.asyncio
async def test_strips_single_block_in_one_chunk() -> None:
    out = await _collect(["<think>the user asks about spacing</think>It is 16 inches."])
    assert out == "It is 16 inches."


@pytest.mark.asyncio
async def test_strips_block_split_across_chunks() -> None:
    # The closing tag and the answer arrive in separate chunks — the leak case.
    out = await _collect(
        ["<think>reasoning ", "continues</thi", "nk>The answer is 16."]
    )
    assert out == "The answer is 16."


@pytest.mark.asyncio
async def test_open_tag_split_across_chunks() -> None:
    out = await _collect(["Hello <", "think>secret</think> world"])
    assert out == "Hello  world"


@pytest.mark.asyncio
async def test_text_before_and_after_block() -> None:
    out = await _collect(["Sure. <think>let me think</think> The max is 16 inches."])
    assert out == "Sure.  The max is 16 inches."


@pytest.mark.asyncio
async def test_multiple_blocks() -> None:
    out = await _collect(["<think>a</think>X<think>b</think>Y"])
    assert out == "XY"


@pytest.mark.asyncio
async def test_unclosed_block_drops_tail() -> None:
    # An unclosed <think> at end-of-stream is reasoning, not answer — drop it.
    out = await _collect(["Answer first. <think>never closed reasoning"])
    assert out == "Answer first. "


@pytest.mark.asyncio
async def test_near_tag_text_not_dropped() -> None:
    # "<thinking>" is not the tag; a "<" that doesn't start a tag must survive.
    assert await _collect(["a < b and c > d"]) == "a < b and c > d"
    assert await _collect(["price < ", "16 always"]) == "price < 16 always"


@pytest.mark.asyncio
async def test_char_by_char_streaming() -> None:
    src = "Hi <think>x</think>there"
    assert await _collect(list(src)) == "Hi there"


@pytest.mark.asyncio
async def test_empty_chunks_ignored() -> None:
    assert await _collect(["", "ok", "", "!"]) == "ok!"
