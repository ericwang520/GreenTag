from contextlib import asynccontextmanager

import pytest
from aiohttp.test_utils import TestClient, TestServer

from events import (
    CodeRequirement,
    EventDispatcher,
    ObservationError,
    build_announcement,
    evaluate_compliance,
    make_events_app,
    parse_field_observation,
    requirement_from_chunks,
)


def _obs_payload(**overrides) -> dict:
    payload = {
        "event": "field_observation.updated",
        "source": "greentag_ios",
        "observation_id": "obs_001",
        "inspection_item": "wood_stud_spacing",
        "location": {"city": "San Francisco", "state": "CA"},
        "measurement": {
            "spacing_in": 15.25,
            "confidence": 0.86,
            "method": "center_to_center",
        },
        "detections": [{"class": "lumber", "confidence": 0.91}],
        "question_for_agent": "Does this pass local framing code, and what should I do next?",
    }
    payload.update(overrides)
    return payload


# --- parsing -----------------------------------------------------------------


def test_parse_valid_observation() -> None:
    obs = parse_field_observation(_obs_payload())
    assert obs.observation_id == "obs_001"
    assert obs.inspection_item == "wood_stud_spacing"
    assert obs.spacing_in == 15.25
    assert obs.confidence == 0.86
    assert obs.location["city"] == "San Francisco"
    assert not obs.low_confidence


def test_parse_rejects_wrong_event_type() -> None:
    with pytest.raises(ObservationError):
        parse_field_observation(_obs_payload(event="something.else"))


def test_parse_rejects_missing_observation_id() -> None:
    p = _obs_payload()
    del p["observation_id"]
    with pytest.raises(ObservationError):
        parse_field_observation(p)


def test_parse_rejects_non_object() -> None:
    with pytest.raises(ObservationError):
        parse_field_observation("not a dict")


def test_low_confidence_flag() -> None:
    obs = parse_field_observation(
        _obs_payload(measurement={"spacing_in": 15.25, "confidence": 0.4})
    )
    assert obs.low_confidence


# --- announcement prompt -----------------------------------------------------


def test_announcement_without_code_avoids_verdict() -> None:
    # No retrieved clause -> agent must not pre-judge or cite a standard.
    user_input, instructions = build_announcement(
        parse_field_observation(_obs_payload())
    )
    assert "15.25" in user_input
    assert "wood stud spacing" in user_input
    assert "Do NOT state whether it passes or fails" in instructions
    assert "code lookup" in instructions


def test_announcement_with_code_pass_cites_clause() -> None:
    obs = parse_field_observation(_obs_payload())  # 15.25"
    code = CodeRequirement(
        citation="IRC R602.3(5)",
        summary="Studs 16 inches on center.",
        max_spacing_in=16.0,
    )
    _, instructions = build_announcement(obs, code)
    assert "IRC R602.3(5)" in instructions
    assert "PASSES" in instructions
    assert (
        "never a number from memory" in instructions.lower()
        or "memory" in instructions.lower()
    )


def test_announcement_with_code_fail() -> None:
    obs = parse_field_observation(
        _obs_payload(measurement={"spacing_in": 19.0, "confidence": 0.9})
    )
    code = CodeRequirement(
        citation="IRC R602.3(5)",
        summary="Studs 16 inches on center.",
        max_spacing_in=16.0,
    )
    _, instructions = build_announcement(obs, code)
    assert "FAILS" in instructions


# --- adapter from Eric's Moss chunks -----------------------------------------


def _moss_chunk(**md) -> dict:
    # Shape returned by backend/greentag/moss_codes.lookup_code.
    metadata = {
        "city": "San Francisco",
        "state": "CA",
        "code": "IRC",
        "section": "R602.3(5)",
    }
    metadata.update(md)
    return {
        "id": "doc_1",
        "score": 0.91,
        "text": "Studs shall be spaced not more than 16 inches on center.",
        "metadata": metadata,
    }


def test_requirement_from_chunks_builds_citation_and_text() -> None:
    req = requirement_from_chunks([_moss_chunk()])
    assert req is not None
    assert req.citation == "IRC R602.3(5)"
    assert "16 inches on center" in req.summary
    assert req.max_spacing_in is None  # Moss doesn't extract a numeric limit


def test_requirement_from_chunks_empty_or_none() -> None:
    assert requirement_from_chunks([]) is None
    assert requirement_from_chunks(None) is None


def test_requirement_from_chunks_missing_metadata_falls_back() -> None:
    req = requirement_from_chunks(
        [{"id": "x", "score": 0.5, "text": "rule", "metadata": {}}]
    )
    assert req is not None
    assert req.citation == "the applicable building code"


def test_announcement_uses_retrieved_chunk_end_to_end() -> None:
    # The realistic path: vision obs + Eric's chunk -> announcement instructions.
    obs = parse_field_observation(_obs_payload())
    code = requirement_from_chunks([_moss_chunk()])
    _, instructions = build_announcement(obs, code)
    assert "IRC R602.3(5)" in instructions
    assert "ONLY this" in instructions  # LLM judges from retrieved text, no memory


# --- deterministic compliance ------------------------------------------------


def test_evaluate_pass_within_tolerance() -> None:
    obs = parse_field_observation(_obs_payload(measurement={"spacing_in": 16.3}))
    code = CodeRequirement(citation="x", summary="y", max_spacing_in=16.0)
    assert evaluate_compliance(obs, code) == "pass"  # 16.3 <= 16 + 0.5 tolerance


def test_evaluate_fail_beyond_tolerance() -> None:
    obs = parse_field_observation(_obs_payload(measurement={"spacing_in": 17.0}))
    code = CodeRequirement(citation="x", summary="y", max_spacing_in=16.0)
    assert evaluate_compliance(obs, code) == "fail"


def test_evaluate_unknown_without_numeric_limit() -> None:
    obs = parse_field_observation(_obs_payload())
    code = CodeRequirement(citation="x", summary="y", max_spacing_in=None)
    assert evaluate_compliance(obs, code) == "unknown"
    assert evaluate_compliance(obs, None) == "unknown"


def test_low_confidence_announcement_hedges() -> None:
    obs = parse_field_observation(
        _obs_payload(measurement={"spacing_in": 15.25, "confidence": 0.4})
    )
    _, instructions = build_announcement(obs)
    assert "rescan" in instructions.lower()


# --- dispatcher / dedup ------------------------------------------------------


@pytest.mark.asyncio
async def test_dispatch_announces_once_then_dedups() -> None:
    spoken: list[str] = []

    async def speak(obs) -> None:
        spoken.append(obs.observation_id)

    dispatcher = EventDispatcher(speak)

    first = await dispatcher.dispatch(_obs_payload())
    assert first["status"] == "announced"

    second = await dispatcher.dispatch(_obs_payload())  # same observation_id
    assert second["status"] == "duplicate"

    assert spoken == ["obs_001"]  # spoken exactly once


@pytest.mark.asyncio
async def test_dispatch_distinct_ids_each_announce() -> None:
    spoken: list[str] = []

    async def speak(obs) -> None:
        spoken.append(obs.observation_id)

    dispatcher = EventDispatcher(speak)
    await dispatcher.dispatch(_obs_payload(observation_id="obs_001"))
    await dispatcher.dispatch(_obs_payload(observation_id="obs_002"))
    assert spoken == ["obs_001", "obs_002"]


@pytest.mark.asyncio
async def test_dispatch_raises_on_bad_event() -> None:
    async def speak(obs) -> None:  # pragma: no cover - should not be called
        raise AssertionError("should not speak on bad event")

    dispatcher = EventDispatcher(speak)
    with pytest.raises(ObservationError):
        await dispatcher.dispatch(_obs_payload(event="nope"))


# --- HTTP layer --------------------------------------------------------------
# Uses aiohttp's built-in TestClient directly to avoid a pytest-aiohttp dep.


@asynccontextmanager
async def _client(speak):
    app = make_events_app(EventDispatcher(speak))
    async with TestClient(TestServer(app)) as client:
        yield client


@pytest.mark.asyncio
async def test_http_post_events_announces() -> None:
    spoken: list[str] = []

    async def speak(obs) -> None:
        spoken.append(obs.observation_id)

    async with _client(speak) as client:
        resp = await client.post("/events", json=_obs_payload())
        assert resp.status == 200
        body = await resp.json()
        assert body["status"] == "announced"
        assert spoken == ["obs_001"]


@pytest.mark.asyncio
async def test_http_post_invalid_json_400() -> None:
    async def speak(obs) -> None:  # pragma: no cover
        pass

    async with _client(speak) as client:
        resp = await client.post("/events", data="not json")
        assert resp.status == 400


@pytest.mark.asyncio
async def test_http_post_bad_event_400() -> None:
    async def speak(obs) -> None:  # pragma: no cover
        raise AssertionError("should not speak")

    async with _client(speak) as client:
        resp = await client.post("/events", json=_obs_payload(event="nope"))
        assert resp.status == 400
        assert (await resp.json())["status"] == "ignored"


@pytest.mark.asyncio
async def test_http_healthz() -> None:
    async def speak(obs) -> None:  # pragma: no cover
        pass

    async with _client(speak) as client:
        resp = await client.get("/healthz")
        assert resp.status == 200
        assert (await resp.json())["status"] == "ok"
