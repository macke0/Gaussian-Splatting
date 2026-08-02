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

from fastapi import FastAPI, HTTPException, UploadFile
from fastapi.responses import FileResponse

from .pipeline import bake_room

log = logging.getLogger(__name__)


@dataclass
class Job:
    id: str
    status: str = "pending"
    detail: str = ""
    directory: Path | None = None
    seen_fraction: float = 0.0
    triangle_count: int = 0
    result: Path | None = field(default=None)


app = FastAPI(title="SpatialFit-bakning")
jobs: dict[str, Job] = {}
# En bakning i taget. Den är minnestung, och två parallella tar inte halva
# tiden — de tar dubbelt så mycket RAM.
workers = ThreadPoolExecutor(max_workers=1)


@app.post("/bake")
async def start_bake(scan: UploadFile) -> dict:
    job = Job(id=uuid.uuid4().hex)
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
            "seenFraction": job.seen_fraction, "triangleCount": job.triangle_count}


@app.get("/bake/{job_id}/mesh")
async def bake_mesh(job_id: str) -> FileResponse:
    return _file(job_id, "baked.mesh", "application/octet-stream")


@app.get("/bake/{job_id}/texture")
async def bake_texture(job_id: str) -> FileResponse:
    return _file(job_id, "baked.png", "image/png")


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
        baked = bake_room(room)
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
