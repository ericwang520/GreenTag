"""HTTP `/events` ingress for vision (iOS) field observations.

vision POSTs `field_observation.updated` events here (see ../../schema.md).
This module owns the *transport + dedup + prompt-building* — i.e. turning a raw
observation into a request for the live `AgentSession` to speak proactively.

Deliberately kept free of any LiveKit session import so the parsing / dedup /
prompt logic is unit-testable without a running room. `agent.py` wires the
`speak` callback to `session.generate_reply(...)`.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from aiohttp import web

logger = logging.getLogger("agent.events")

EVENT_TYPE = "field_observation.updated"

# Below this measurement confidence, the agent should hedge ("possibly / please
# rescan") rather than state a value flatly. See schema.md step 3.
LOW_CONFIDENCE_THRESHOLD = 0.6

# Slack allowed on a deterministic spacing comparison, in inches, to absorb
# measurement noise. A reading of 16.3" against a 16" limit shouldn't fail.
SPACING_TOLERANCE_IN = 0.5

# Cap the retrieved clause text fed into the announcement prompt, to keep TTS
# latency sane. The top chunk is the most relevant; the LLM judges from it.
MAX_CLAUSE_CHARS = 600

# Wake words that summon the agent into a conversation. Until it hears one, the
# agent stays quiet on user speech (so site chatter / its own echo never makes
# it answer) — proactive measurement announcements are unaffected. Matching is
# substring + lowercased to tolerate STT spacing ("green tag") and punctuation.
WAKE_WORDS = (
    "hey greentag",
    "hey green tag",
    "ok greentag",
    "okay greentag",
    "greentag",
    "green tag",
    "hey inspector",
)


def contains_wake_word(text: str | None) -> bool:
    """True if `text` contains any wake word (case-insensitive substring)."""
    if not text:
        return False
    lowered = text.lower()
    return any(word in lowered for word in WAKE_WORDS)


@dataclass
class CodeRequirement:
    """What the agent announces and cites — the agent-side view of a retrieved
    clause. Sourced from Eric's Moss retrieval (backend/greentag/moss_codes.py)
    via `requirement_from_chunks`; this module never retrieves anything itself.
    """

    citation: str  # e.g. "IRC R602.3(5)" — what the agent cites out loud
    summary: str  # the retrieved clause text the agent judges/speaks from
    max_spacing_in: float | None = (
        None  # numeric limit if known; pass if measured <= this
    )
    source: str | None = None  # provenance for the dashboard, e.g. "IRC (model)"


def requirement_from_chunks(chunks: list[dict] | None) -> CodeRequirement | None:
    """Adapt Eric's Moss chunks -> the agent's CodeRequirement.

    Eric's `lookup_code` returns `[{id, score, text, metadata}]` sorted by score
    (see backend/greentag/moss_codes.py). We take the top chunk, build a citation
    from its code+section metadata, and carry the clause text for the agent to
    judge from. Moss doesn't extract a numeric limit, so `max_spacing_in` stays
    None and the LLM reasons from the clause text. Returns None if nothing was
    retrieved (the agent then stays tentative).
    """
    if not chunks:
        return None
    top = chunks[0]
    md = top.get("metadata") or {}
    code = (md.get("code") or "").strip()
    section = (md.get("section") or "").strip()
    citation = (
        " ".join(p for p in (code, section) if p) or "the applicable building code"
    )
    summary = (top.get("text") or "").strip()[:MAX_CLAUSE_CHARS]
    return CodeRequirement(citation=citation, summary=summary, source=code or None)


@dataclass
class FieldObservation:
    """A single measurement from vision. Mirrors schema.md FieldObservation.

    Only the fields the agent needs to *speak* are required; everything else is
    kept in `raw` for the demo dashboard / future RAG consumption.
    """

    observation_id: str
    inspection_item: str
    spacing_in: float | None
    confidence: float | None
    question_for_agent: str | None
    location: dict
    raw: dict = field(default_factory=dict)

    @property
    def low_confidence(self) -> bool:
        return (
            self.confidence is not None and self.confidence < LOW_CONFIDENCE_THRESHOLD
        )


class ObservationError(ValueError):
    """Payload was not a usable field_observation event."""


def parse_field_observation(payload: object) -> FieldObservation:
    """Validate and extract a FieldObservation from a decoded JSON payload.

    Raises ObservationError for anything that isn't a usable observation event.
    """
    if not isinstance(payload, dict):
        raise ObservationError("payload must be a JSON object")

    event = payload.get("event")
    if event != EVENT_TYPE:
        raise ObservationError(f"unsupported event type: {event!r}")

    observation_id = payload.get("observation_id")
    if not isinstance(observation_id, str) or not observation_id:
        raise ObservationError("missing observation_id")

    inspection_item = payload.get("inspection_item")
    if not isinstance(inspection_item, str) or not inspection_item:
        raise ObservationError("missing inspection_item")

    measurement = payload.get("measurement") or {}
    if not isinstance(measurement, dict):
        raise ObservationError("measurement must be an object")

    spacing_in = measurement.get("spacing_in")
    if spacing_in is not None and not isinstance(spacing_in, (int, float)):
        raise ObservationError("measurement.spacing_in must be a number")

    confidence = measurement.get("confidence")
    if confidence is not None and not isinstance(confidence, (int, float)):
        raise ObservationError("measurement.confidence must be a number")

    location = payload.get("location") or {}
    if not isinstance(location, dict):
        raise ObservationError("location must be an object")

    question = payload.get("question_for_agent")
    if question is not None and not isinstance(question, str):
        raise ObservationError("question_for_agent must be a string")

    return FieldObservation(
        observation_id=observation_id,
        inspection_item=inspection_item,
        spacing_in=float(spacing_in) if spacing_in is not None else None,
        confidence=float(confidence) if confidence is not None else None,
        question_for_agent=question,
        location=location,
        raw=payload,
    )


def evaluate_compliance(obs: FieldObservation, code: CodeRequirement | None) -> str:
    """Deterministic pass/fail when the retrieved clause gives a numeric limit.

    Returns "pass", "fail", or "unknown". "unknown" means there's no numeric
    limit to compare against — the agent reasons from the clause text instead.
    """
    if code is None or code.max_spacing_in is None or obs.spacing_in is None:
        return "unknown"
    return (
        "pass"
        if obs.spacing_in <= code.max_spacing_in + SPACING_TOLERANCE_IN
        else "fail"
    )


def build_announcement(
    obs: FieldObservation, code: CodeRequirement | None = None
) -> tuple[str, str]:
    """Build (user_input, instructions) for `session.generate_reply`.

    Without `code` (Moss RAG not wired, or no clause found) the agent only
    announces the measurement and says it's checking against local code — it must
    NOT invent a standard. With `code`, the retrieved clause is the source of
    truth (per schema.md: the standard comes from the spec library, never the
    client), and the agent announces the verdict and cites the clause.
    """
    loc = obs.location or {}
    where = ", ".join(str(v) for v in (loc.get("city"), loc.get("state")) if v)

    facts = [f"Inspection item: {obs.inspection_item.replace('_', ' ')}."]
    if obs.spacing_in is not None:
        facts.append(f"Measured spacing: {obs.spacing_in} inches, center to center.")
    if obs.confidence is not None:
        facts.append(f"Measurement confidence: {obs.confidence:.0%}.")
    if where:
        facts.append(f"Location: {where}.")
    user_input = " ".join(facts)
    if obs.question_for_agent:
        user_input += f" The field question is: {obs.question_for_agent}"

    hedge = (
        "The measurement confidence is LOW. Speak tentatively — say the reading "
        "is approximate and suggest rescanning before relying on the result. "
        if obs.low_confidence
        else ""
    )

    if code is None:
        verdict_directive = (
            "Do NOT state whether it passes or fails code, and do NOT cite any spacing "
            "standard or number from memory — the official requirement must come from a "
            "code lookup that happens separately. Say you're checking it against local "
            "code and will report the result."
        )
    else:
        verdict = evaluate_compliance(obs, code)
        clause = f"The applicable code is {code.citation}: {code.summary}"
        if verdict == "pass":
            verdict_directive = (
                f"{clause} Based on this, the measurement PASSES. Announce that it "
                f"passes and cite {code.citation}. Only use this retrieved standard — "
                "never a number from memory."
            )
        elif verdict == "fail":
            verdict_directive = (
                f"{clause} Based on this, the measurement FAILS — the spacing exceeds "
                f"the allowed limit. Announce that it does not pass, cite {code.citation}, "
                "and briefly say what's needed to comply. Only use this retrieved standard."
            )
        else:  # unknown — let the LLM judge from the clause text
            verdict_directive = (
                f"{clause} Judge whether the measurement complies using ONLY this "
                f"retrieved requirement, cite {code.citation}, and state the result. "
                "Never use a standard from memory."
            )

    instructions = (
        "You are GreenTag, a seasoned framing inspector talking to the contractor "
        "on site through an earpiece. A new measurement just came in from their "
        "camera. Announce it in one or two short spoken sentences, always in this "
        "order: the bottom-line result, the measurement in plain speech, then the "
        "code reason. "
        f"{hedge}{verdict_directive} "
        "Make it sound like real speech: use contractions, say numbers as words "
        "(\"sixteen and a quarter inches\", not \"sixteen point two five inches\"), "
        "and read any code reference conversationally: say \"section six oh two\" "
        "instead of reciting punctuation or parentheses. No lists, labels, raw "
        "JSON, tool names, or filler like \"inspection item\". Keep it under "
        "about thirty words and end on the clear takeaway for the contractor."
    )
    return user_input, instructions


# Callback the HTTP layer invokes to make the agent speak. Wired to the live
# AgentSession in agent.py. Returns when the utterance has been handed to TTS.
SpeakFn = Callable[[FieldObservation], Awaitable[None]]


class EventDispatcher:
    """Dedups observations by id and drives the agent's proactive speech."""

    def __init__(self, speak: SpeakFn) -> None:
        self._speak = speak
        self._seen: set[str] = set()

    async def dispatch(self, payload: object) -> dict:
        """Process one decoded payload. Raises ObservationError if unusable."""
        obs = parse_field_observation(payload)

        if obs.observation_id in self._seen:
            logger.info(
                "duplicate observation, skipping announce: %s", obs.observation_id
            )
            return {"status": "duplicate", "observation_id": obs.observation_id}

        self._seen.add(obs.observation_id)
        logger.info(
            "field_observation %s (%s, conf=%s) -> announcing",
            obs.observation_id,
            obs.inspection_item,
            obs.confidence,
        )
        await self._speak(obs)
        return {"status": "announced", "observation_id": obs.observation_id}


def make_events_app(dispatcher: EventDispatcher) -> web.Application:
    """Build the aiohttp app exposing POST /events and GET /healthz."""

    async def handle_events(request: web.Request) -> web.Response:
        try:
            payload = await request.json()
        except Exception:
            return web.json_response(
                {"status": "error", "reason": "invalid JSON"}, status=400
            )

        try:
            result = await dispatcher.dispatch(payload)
        except ObservationError as e:
            return web.json_response(
                {"status": "ignored", "reason": str(e)}, status=400
            )
        except Exception:
            logger.exception("failed to dispatch observation")
            return web.json_response(
                {"status": "error", "reason": "internal error"}, status=500
            )

        return web.json_response(result, status=200)

    async def handle_health(_: web.Request) -> web.Response:
        return web.json_response({"status": "ok"})

    app = web.Application()
    app.add_routes(
        [
            web.post("/events", handle_events),
            web.get("/healthz", handle_health),
        ]
    )
    return app
