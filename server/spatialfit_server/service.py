"""HTTP-tjänsten telefonen laddar upp sin skanning till.

Bakningen tar minuter, inte millisekunder, så uppladdningen svarar med ett
jobb-id och telefonen frågar efter resultatet. Ett svar som kommer efter tio
minuters öppen anslutning överlever varken mobilnät eller att skärmen släcks.

Jobben ligger i minnet. Servern är ett verktyg för en maskin i ett rum, inte en
molntjänst — dör den är den snabbaste vägen framåt att skicka upp skanningen
igen, inte att återuppta ett halvfärdigt jobb.
"""

from __future__ import annotations

import logging
import shutil
import tempfile
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

from fastapi import FastAPI, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool

from .identify import VisionError, describe
from .pipeline import COLOR_SOURCES, DEFAULT_COLOR_SOURCE, bake_room

log = logging.getLogger(__name__)


@dataclass
class Job:
    id: str
    status: str = "pending"
    detail: str = ""
    directory: Path | None = None
    color_source: str = DEFAULT_COLOR_SOURCE
    seen_fraction: float = 0.0
    triangle_count: int = 0
    result: Path | None = field(default=None)


# Ett utsnitt ur ett foto, inte ett foto. Blir det större är det något annat som
# skickats upp av misstag.
MAXIMUM_CROP_BYTES = 8 * 1024 * 1024

app = FastAPI(title="SpatialFit-bakning")
# uvicorn sätter upp sina egna loggare och lämnar rotloggaren tyst, så våra rader
# — hur många gaussare, hur stor del av texlarna som såg ett foto — försvann helt
# och serverloggen bestod av åtkomstrader. Det är de raderna man behöver när
# någon undrar varför ett rum blev suddigt.
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
logging.getLogger("spatialfit_server").setLevel(logging.INFO)

jobs: dict[str, Job] = {}
# En bakning i taget. Den är minnestung, och två parallella tar inte halva
# tiden — de tar dubbelt så mycket RAM.
workers = ThreadPoolExecutor(max_workers=1)


@app.post("/bake")
async def start_bake(scan: UploadFile,
                     color_source: str = Form(DEFAULT_COLOR_SOURCE)) -> dict:
    if color_source not in COLOR_SOURCES:
        raise HTTPException(status_code=400,
                            detail=f"okänd färgkälla {color_source!r}")

    job = Job(id=uuid.uuid4().hex, color_source=color_source)
    directory = Path(tempfile.mkdtemp(prefix=f"bake-{job.id}-"))
    job.directory = directory

    archive = directory / "scan.zip"
    with archive.open("wb") as handle:
        shutil.copyfileobj(scan.file, handle)

    room = directory / "room"
    room.mkdir()
    try:
        _extract(archive, room)
    except (zipfile.BadZipFile, ValueError) as error:
        shutil.rmtree(directory, ignore_errors=True)
        raise HTTPException(status_code=400, detail=str(error)) from error

    jobs[job.id] = job
    workers.submit(_run, job, room)
    return {"id": job.id, "status": job.status}


@app.get("/bake/{job_id}")
async def bake_status(job_id: str) -> dict:
    job = jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="okänt jobb")
    return {"id": job.id, "status": job.status, "detail": job.detail,
            "seenFraction": job.seen_fraction, "triangleCount": job.triangle_count,
            "hasSplat": job.result is not None and (job.result / "splat.spz").exists()}


@app.get("/bake/{job_id}/mesh")
async def bake_mesh(job_id: str) -> FileResponse:
    return _file(job_id, "baked.mesh", "application/octet-stream")


@app.get("/bake/{job_id}/texture")
async def bake_texture(job_id: str) -> FileResponse:
    return _file(job_id, "baked.png", "image/png")


@app.get("/bake/{job_id}/splat")
async def bake_splat(job_id: str) -> FileResponse:
    """Splatten som SPZ. Finns bara när färgkällan var ``splat``."""
    return _file(job_id, "splat.spz", "application/octet-stream")


@app.post("/identify")
async def identify(crop: UploadFile, hint: str = Form("")) -> dict:
    """Vad utsnittet föreställer. En bild i taget, så telefonen kan visa svaren
    efter hand i stället för att vänta ut hela rummet."""
    image = await crop.read()
    if not image:
        raise HTTPException(status_code=400, detail="tom bild")
    if len(image) > MAXIMUM_CROP_BYTES:
        raise HTTPException(status_code=413, detail="utsnittet är för stort")

    try:
        return await run_in_threadpool(describe, image, hint or None)
    except VisionError as error:
        raise HTTPException(status_code=502, detail=str(error)) from error


def _file(job_id: str, name: str, media_type: str) -> FileResponse:
    """Två raka nedladdningar i stället för ett arkiv: iOS kan packa ihop en
    mapp utan beroenden, men inte packa upp en."""
    job = jobs.get(job_id)
    if job is None or job.result is None:
        raise HTTPException(status_code=404, detail="resultatet finns inte")

    path = job.result / name
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"{name} saknas")
    return FileResponse(path, media_type=media_type, filename=name)


def _run(job: Job, room: Path) -> None:
    job.status = "running"
    try:
        baked = bake_room(room, color_source=job.color_source)
        output = room.parent / "output"
        baked.write(output)

        job.result = output
        job.seen_fraction = baked.seen_fraction
        job.triangle_count = baked.triangle_count
        job.status = "done"
    except Exception as error:  # noqa: BLE001 — felet ska nå telefonen, inte loggen
        log.exception("bakningen misslyckades")
        job.status = "failed"
        job.detail = str(error)


def _extract(archive: Path, destination: Path) -> None:
    """Packar upp platt. Ett zip-arkiv får inte skriva utanför sin mapp."""
    with zipfile.ZipFile(archive) as zipped:
        for entry in zipped.infolist():
            if entry.is_dir():
                continue
            name = Path(entry.filename).name
            if not name or name.startswith("."):
                continue
            with zipped.open(entry) as source, (destination / name).open("wb") as target:
                shutil.copyfileobj(source, target)
