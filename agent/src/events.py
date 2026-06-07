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
import re
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from aiohttp import web

logger = logging.getLogger("agent.events")

EVENT_TYPE = "field_observation.updated"

# Single confidence gate for the whole agent (schema.md / CLAUDE.md: "if
# measurement.confidence < 0.85, agent says re-aim, not a verdict"). Below this
# the agent must hedge ("approximate / re-aim") rather than rule on the reading.
# One constant on purpose so the proactive announcement and the conversational
# get_current_reading tool agree — and so the iOS lock gate can match it.
LOW_CONFIDENCE_THRESHOLD = 0.85

# Slack allowed on a deterministic spacing comparison, in inches, to absorb
# measurement noise. A reading of 16.3" against a 16" limit shouldn't fail.
SPACING_TOLERANCE_IN = 0.5

# Cap the retrieved clause text fed into the announcement prompt, to keep TTS
# latency sane. The top chunk is the most relevant; the LLM judges from it.
MAX_CLAUSE_CHARS = 600

NUMBER_WORDS = {
    0: "zero",
    1: "one",
    2: "two",
    3: "three",
    4: "four",
    5: "five",
    6: "six",
    7: "seven",
    8: "eight",
    9: "nine",
    10: "ten",
    11: "eleven",
    12: "twelve",
    13: "thirteen",
    14: "fourteen",
    15: "fifteen",
    16: "sixteen",
    17: "seventeen",
    18: "eighteen",
    19: "nineteen",
    20: "twenty",
    21: "twenty-one",
    22: "twenty-two",
    23: "twenty-three",
    24: "twenty-four",
    25: "twenty-five",
    26: "twenty-six",
    27: "twenty-seven",
    28: "twenty-eight",
    29: "twenty-nine",
    30: "thirty",
}

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
    max_spacing = _default_max_spacing(top)
    return CodeRequirement(
        citation=citation,
        summary=summary,
        max_spacing_in=max_spacing,
        source=code or None,
    )


def _default_max_spacing(chunk: dict) -> float | None:
    """Best-effort numeric max from Moss metadata for deterministic speech."""
    value = chunk.get("default_max_spacing_in")
    if value is None:
        value = (chunk.get("metadata") or {}).get("default_max_spacing_in")
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


@dataclass
class MeasurementReading:
    spacing_in: float | None
    confidence: float | None
    label: str | None = None

    @property
    def low_confidence(self) -> bool:
        return (
            self.confidence is not None and self.confidence < LOW_CONFIDENCE_THRESHOLD
        )


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
    measurements: list[MeasurementReading]
    inspection_summary: dict | None
    question_for_agent: str | None
    location: dict
    # Whether this observation should trigger a proactive spoken announcement.
    # iOS streams readings continuously to keep `latest_observation` fresh with
    # announce=false (state only, silent); the explicit "lock & check" tap sends
    # announce=true. Defaults true so the HTTP/curl/browser path and older
    # payloads keep their announce-on-arrival behavior.
    announce: bool = True
    raw: dict = field(default_factory=dict)

    @property
    def low_confidence(self) -> bool:
        if self.measurements:
            return any(reading.low_confidence for reading in self.measurements)
        return self.confidence is not None and self.confidence < LOW_CONFIDENCE_THRESHOLD


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

    measurements = _parse_measurements(payload.get("measurements"))
    if not measurements and (spacing_in is not None or confidence is not None):
        measurements = [
            MeasurementReading(
                spacing_in=float(spacing_in) if spacing_in is not None else None,
                confidence=float(confidence) if confidence is not None else None,
                label="primary",
            )
        ]

    inspection_summary = payload.get("inspection_summary")
    if inspection_summary is not None and not isinstance(inspection_summary, dict):
        raise ObservationError("inspection_summary must be an object")

    location = payload.get("location") or {}
    if not isinstance(location, dict):
        raise ObservationError("location must be an object")

    question = payload.get("question_for_agent")
    if question is not None and not isinstance(question, str):
        raise ObservationError("question_for_agent must be a string")

    # Silent state-only stream updates set announce=false; default true so the
    # established announce-on-arrival behavior is unchanged when the key is absent.
    announce = payload.get("announce", True)
    if not isinstance(announce, bool):
        raise ObservationError("announce must be a boolean")

    return FieldObservation(
        observation_id=observation_id,
        inspection_item=inspection_item,
        spacing_in=float(spacing_in) if spacing_in is not None else None,
        confidence=float(confidence) if confidence is not None else None,
        measurements=measurements,
        inspection_summary=inspection_summary,
        question_for_agent=question,
        location=location,
        announce=announce,
        raw=payload,
    )


def _parse_measurements(value: object) -> list[MeasurementReading]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise ObservationError("measurements must be an array")

    readings: list[MeasurementReading] = []
    for item in value:
        if not isinstance(item, dict):
            raise ObservationError("measurements entries must be objects")

        spacing_in = item.get("spacing_in")
        if spacing_in is not None and not isinstance(spacing_in, (int, float)):
            raise ObservationError("measurements.spacing_in must be a number")

        confidence = item.get("confidence")
        if confidence is not None and not isinstance(confidence, (int, float)):
            raise ObservationError("measurements.confidence must be a number")

        label = item.get("label")
        if label is not None and not isinstance(label, str):
            raise ObservationError("measurements.label must be a string")

        readings.append(
            MeasurementReading(
                spacing_in=float(spacing_in) if spacing_in is not None else None,
                confidence=float(confidence) if confidence is not None else None,
                label=label,
            )
        )

    return readings


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


def build_spoken_announcement(
    obs: FieldObservation, code: CodeRequirement | None = None
) -> str:
    """Build the exact sentence sent to TTS for proactive measurements.

    This path intentionally avoids an LLM. The iPhone has already sent a raw
    measurement, and Moss has already returned the applicable clause, so the
    safest voice behavior is a short deterministic line with no hidden reasoning
    stream that can leak into audio.
    """
    if len(obs.measurements) > 1:
        return build_multi_measurement_announcement(obs, code)

    measurement = (
        f"{format_inches(obs.spacing_in)} center to center"
        if obs.spacing_in is not None
        else "that spacing"
    )

    if obs.low_confidence:
        return f"I have an approximate read at {measurement}. Re-scan before relying on it."

    if code is None:
        return f"I have the measurement at {measurement}. I'm checking it against local code now."

    verdict = evaluate_compliance(obs, code)
    citation = format_citation(code.citation)
    if verdict == "pass":
        return f"Pass. Measured {measurement}; {citation} allows up to {format_inches(code.max_spacing_in)}."
    if verdict == "fail":
        return f"Fail. Measured {measurement}; {citation} allows up to {format_inches(code.max_spacing_in)}."
    return f"Measured {measurement}. I found {citation}, but I need the wall load case before calling pass or fail."


def build_multi_measurement_announcement(
    obs: FieldObservation, code: CodeRequirement | None = None
) -> str:
    readable = [
        reading for reading in obs.measurements if reading.spacing_in is not None
    ]
    if not readable:
        return build_spoken_announcement(
            FieldObservation(
                observation_id=obs.observation_id,
                inspection_item=obs.inspection_item,
                spacing_in=obs.spacing_in,
                confidence=obs.confidence,
                measurements=[],
                inspection_summary=obs.inspection_summary,
                question_for_agent=obs.question_for_agent,
                location=obs.location,
                raw=obs.raw,
            ),
            code,
        )

    if obs.low_confidence:
        return "I have multiple approximate spacing reads. Re-scan before relying on them."

    if code is None or code.max_spacing_in is None:
        pieces = [
            f"{format_label(reading.label)} is {format_inches(reading.spacing_in)}"
            for reading in readable
        ]
        return f"I measured {join_spoken_list(pieces)} center to center. I'm checking them against local code now."

    citation = format_citation(code.citation)
    pieces = []
    failed = False
    for reading in readable:
        passes = reading.spacing_in <= code.max_spacing_in + SPACING_TOLERANCE_IN
        failed = failed or not passes
        result = "passes" if passes else "fails"
        pieces.append(
            f"{format_label(reading.label)} {result} at {format_inches(reading.spacing_in)}"
        )

    bottom_line = "Fail" if failed else "Pass"
    return (
        f"{bottom_line}. {join_spoken_list(pieces)}. "
        f"{citation} allows up to {format_inches(code.max_spacing_in)}."
    )


def format_inches(value: float | None) -> str:
    """Speak common inch measurements without decimal-point phrasing."""
    if value is None:
        return "that many inches"
    quarters = round(value * 4)
    whole = quarters // 4
    frac = quarters % 4
    whole_words = _number_words(whole)
    if frac == 0:
        return f"{whole_words} inches"
    fraction_words = {
        1: "a quarter",
        2: "a half",
        3: "three quarters",
    }[frac]
    if whole == 0:
        return f"{fraction_words} inch"
    return f"{whole_words} and {fraction_words} inches"


def format_citation(citation: str) -> str:
    """Make code citations less awkward for TTS."""
    cleaned = citation.strip()
    cleaned = re.sub(r"\s+", " ", cleaned)
    cleaned = cleaned.replace("R", "section R", 1) if cleaned.startswith("R") else cleaned
    cleaned = cleaned.replace("(", " ").replace(")", "")
    return cleaned


def format_label(label: str | None) -> str:
    normalized = (label or "").strip().lower().replace("_", " ")
    if normalized in {"left", "left span"}:
        return "left span"
    if normalized in {"right", "right span"}:
        return "right span"
    if normalized:
        return normalized
    return "one span"


def join_spoken_list(items: list[str]) -> str:
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    if len(items) == 2:
        return f"{items[0]}, and {items[1]}"
    return ", ".join(items[:-1]) + f", and {items[-1]}"


def _number_words(value: int) -> str:
    return NUMBER_WORDS.get(value, str(value))


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
    summary = format_inspection_summary(obs.inspection_summary)
    if summary:
        facts.append(summary)
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
        '("sixteen and a quarter inches", not "sixteen point two five inches"), '
        'and read any code reference conversationally: say "section six oh two" '
        "instead of reciting punctuation or parentheses. No lists, labels, raw "
        'JSON, tool names, or filler like "inspection item". Keep it under '
        "about thirty words and end on the clear takeaway for the contractor."
    )
    return user_input, instructions


def format_inspection_summary(summary: dict | None) -> str:
    if not summary:
        return ""
    checks = summary.get("checks")
    if not isinstance(checks, list) or not checks:
        return ""

    described_checks = []
    for check in checks[-3:]:
        if not isinstance(check, dict):
            continue
        spans = check.get("spans")
        if not isinstance(spans, list):
            continue
        described_spans = []
        for span in spans:
            if not isinstance(span, dict):
                continue
            label = span.get("label")
            spacing = span.get("spacing_in")
            verdict = span.get("verdict")
            if not isinstance(spacing, (int, float)):
                continue
            described_spans.append(
                f"{format_label(label if isinstance(label, str) else None)} "
                f"{spacing:.2f} inches {verdict if isinstance(verdict, str) else 'measured'}"
            )
        if described_spans:
            described_checks.append("; ".join(described_spans))

    if not described_checks:
        return ""

    return "Current inspection history: " + " | ".join(described_checks) + "."


def format_current_reading(obs: FieldObservation | None) -> str:
    """Render the latest reading for the `get_current_reading` conversational tool.

    This is the on-demand counterpart to `build_announcement`: when the contractor
    asks "is this one ok?", the tool returns this so the LLM judges from the real
    live measurement instead of guessing. Kept here (not in agent.py) so it stays
    unit-testable without a running session. Like the announcement path, it never
    states a code standard — it only reports the measured facts and flags low
    confidence; the agent still calls the code lookup for the requirement.
    """
    if obs is None:
        return (
            "No measurement has come in from the camera yet. Ask the contractor to "
            "aim at the wall and hold steady until a reading locks."
        )

    parts: list[str] = []
    if obs.spacing_in is not None:
        parts.append(f"measured spacing is {obs.spacing_in} inches, center to center")
    if obs.confidence is not None:
        parts.append(f"measurement confidence is {obs.confidence:.0%}")
    city = (obs.location or {}).get("city")
    if city:
        parts.append(f"the job site is in {city}")
    body = "; ".join(parts) if parts else "a reading is in but carries no spacing value"

    if obs.low_confidence:
        return (
            f"The current {body}. Confidence is LOW — tell the contractor the reading "
            "is approximate and to re-aim and hold steady before trusting it; do not "
            "give a pass or fail yet."
        )
    return f"The current {body}."


class ObservationStore:
    """Holds the most recent field observation for on-demand conversation.

    The proactive announcement path consumes each observation as it arrives; this
    store keeps the *latest* one alive so the `get_current_reading` tool can answer
    "is this one ok?" at any time. Per CLAUDE.md the agent "keeps the latest one as
    latest_observation" — this is that. Updated on every valid observation (even a
    deduped re-send), so what the agent can look up never goes stale.
    """

    def __init__(self) -> None:
        self._latest: FieldObservation | None = None

    def update(self, obs: FieldObservation) -> None:
        self._latest = obs

    @property
    def latest(self) -> FieldObservation | None:
        return self._latest


# Callback the HTTP layer invokes to make the agent speak. Wired to the live
# AgentSession in agent.py. Returns when the utterance has been handed to TTS.
SpeakFn = Callable[[FieldObservation], Awaitable[None]]


class EventDispatcher:
    """Dedups observations by id and drives the agent's proactive speech.

    Also refreshes the optional `store` with every valid observation so the
    conversational `get_current_reading` tool always sees the latest reading —
    dedup only gates *speaking*, never *remembering*.
    """

    def __init__(self, speak: SpeakFn, store: ObservationStore | None = None) -> None:
        self._speak = speak
        self._store = store
        self._seen: set[str] = set()

    async def dispatch(self, payload: object) -> dict:
        """Process one decoded payload. Raises ObservationError if unusable."""
        obs = parse_field_observation(payload)

        # Remember the latest reading before any gate, so a re-sent id or a silent
        # stream update still keeps the conversation's view current.
        if self._store is not None:
            self._store.update(obs)

        # Silent stream update (iOS continuous readings): refresh state, stay quiet.
        if not obs.announce:
            return {"status": "stored", "observation_id": obs.observation_id}

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
