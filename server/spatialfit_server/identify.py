"""Finkornig identifiering av en pjäs ur ett foto.

RoomPlan vet redan att något är en spis, och hur stor lådan är. Det den inte vet
är vilken spis: fabrikat, kulör, om hällen är induktion eller gjutjärn. Det är
den upplysningen som gör att en produkt ur PIM går att föreslå som ersättare, och
den finns bara i bilden.

Servern tolkar alltså inte rummet — den tittar på en utklippt bild och svarar med
en text. Geometrin och måtten stannar på telefonen, precis som för bakningen.

Modellen körs av ollama på samma maskin. Den är en GISSNING och märks som det:
inget härifrån får bli ett mått.
"""

from __future__ import annotations

import base64
import json
import os
import urllib.error
import urllib.request

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("SPATIALFIT_VISION_MODEL", "qwen2.5vl")
TIMEOUT_SECONDS = 120

# Inga exempelsträngar i prompten. Med sådana svarade qwen2.5vl med exemplet
# ordagrant på två av fem bilder — den skrev av i stället för att titta.
PROMPT = """Du tittar på ett utsnitt ur ett foto av ett kök eller badrum.
Beskriv FÖREMÅLET I MITTEN så att det går att slå upp i en produktkatalog.

Svara med JSON och ingenting annat, med de här fälten:
- "kind": vad föremålet är, ett eller två ord.
- "detail": det som skiljer just detta exemplar från andra av samma sort —
  material, kulör, ytbehandling, typ av lucka eller häll. Upprepa inte "kind".
- "confidence": ett tal mellan 0.0 och 1.0.

Beskriv bara det du ser. Gissa inte fabrikat om det inte står läsbart i bilden,
och hitta inte på detaljer när utsnittet är suddigt — sänk "confidence" i
stället. Svara på svenska."""


class VisionError(RuntimeError):
    """Modellen gick inte att nå eller svarade obegripligt."""


def describe(image: bytes, hint: str | None = None) -> dict:
    """Vad bilden föreställer, som ``{"kind", "detail", "confidence"}``.

    ``hint`` är RoomPlans egen klassning. Den skickas med för att hålla svaret
    på rätt sak när utsnittet råkar få med grannskåpet, men modellen får säga
    emot den — RoomPlan tar ofta en diskmaskin för ett skåp.
    """
    prompt = PROMPT
    if hint:
        prompt += f"\n\nSkanningen tror att det är: {hint}. Rätta den om den har fel."

    payload = {
        "model": MODEL,
        "prompt": prompt,
        "images": [base64.b64encode(image).decode("ascii")],
        "stream": False,
        "format": "json",
        # Låg temperatur: det här är en avläsning, inte en text som ska vara
        # trevlig att läsa. Samma bild ska ge samma svar.
        "options": {"temperature": 0.1},
    }
    return _parse(_ask(payload))


def _ask(payload: dict) -> str:
    request = urllib.request.Request(
        f"{OLLAMA_URL}/api/generate",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            body = json.load(response)
    except urllib.error.URLError as error:
        raise VisionError(f"når inte modellen på {OLLAMA_URL}: {error.reason}") from error
    except json.JSONDecodeError as error:
        raise VisionError("modellen svarade inte med JSON") from error
    return body.get("response", "")


def _parse(answer: str) -> dict:
    try:
        parsed = json.loads(answer)
    except json.JSONDecodeError as error:
        raise VisionError(f"kunde inte tolka svaret: {answer[:200]!r}") from error
    if not isinstance(parsed, dict):
        raise VisionError(f"väntade ett objekt, fick {type(parsed).__name__}")

    confidence = parsed.get("confidence", 0.0)
    return {
        "kind": str(parsed.get("kind", "")).strip(),
        "detail": str(parsed.get("detail", "")).strip(),
        "confidence": float(confidence) if isinstance(confidence, (int, float)) else 0.0,
    }
