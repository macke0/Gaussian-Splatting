"""Skanningen som telefonen skickar upp.

Rummets mapp packas som den ligger: ``room.mesh``, ``keyframes.json`` och ett
par foton med tillhörande djupkartor. Inget skrivs om på vägen — det som bakas
ska vara samma data som appen mätte i.

``keyframes.json`` kommer ur Swifts ``JSONEncoder``. SIMD-typer kodas som
listor, och matriserna är kolumnvisa. Det är därför kolumnerna staplas och
transponeras här i stället för att läsas rad för rad.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from .mesh import SceneMesh

#: Hur liten en fritt liggande del får vara innan den räknas som skräp, som
#: andel av den största delens area. ARKit lämnar flagor efter sig när LiDAR
#: läser av en spegling eller en rörlig sak: de hänger ihop med ingenting och
#: svävar mitt i rummet. Uppmätt på det riktiga rummet: 419 sådana delar,
#: 1,76 m² av 67, med 35 cm i median ut till närmaste riktiga yta.
LOOSE_PIECE_FRACTION = 0.005

#: Hur långt före eller efter djupkartans yta en punkt får ligga och ändå räknas
#: som samma yta. LiDAR:ns eget brus är ±10 mm och poserna missar några
#: millimeter; fem centimeter rymmer båda utan att släppa igenom luft.
FREE_SPACE_MARGIN = 0.05

#: Andelen foton som måste ge en punkt medhåll, av dem som har en åsikt.
#: Uppmätt på det riktiga rummet: en punkt i luften har 2 vittnen mot 45
#: motsägelser (enighet 0,06), en punkt på ytan 20 mot 5 (0,79) — två skilda
#: populationer, inte en glidande skala. Gränsen ligger ändå lågt, för svepet
#: har en knä där: 0,25 kastar 80 % av luften och behåller 92 % av ytan, medan
#: 0,5 bara tar 12 procentenheter luft till och kostar 14 av ytan.
MINIMUM_AGREEMENT = 0.25

#: Suddningskärnans bredd i Crete-Roffets oskärpemått. Nio är hans eget val och
#: ska inte skruvas på: ändras den går talen inte att jämföra med publicerade.
BLUR_SPAN = 9

#: Oskärpa vid och under vilken ett foto får full vikt. Vår median ligger på
#: 0,343 och mipnerf360/``room`` på 0,323, så de flesta foton är hela.
SHARP_ENOUGH = 0.35

#: Oskärpa vid och över vilken ett foto bara får golvet. Kalibrerat mot känd
#: gaussisk suddning ligger 0,50 mellan en och två pixlars sudd — sett med ögat
#: blir tavelramar streck och krukväxter gröna smetar. 10 % av fotona i det
#: riktiga rummet ligger över 0,44, 4 % över 0,47.
TOO_BLURRY = 0.50

#: Minsta vikt ett foto kan få. ALDRIG noll: att GALLRA suddiga foton är prövat
#: och knäckte geometrin, och nu vet vi varför — suddet KLUMPAR SIG i tid
#: (grannskillnad 0,045 mot 0,078 i slumpad ordning), så skurarna är hela vyer
#: tagna när kunden svänger. Kastas de försvinner täckningen av just de
#: vinklarna. Ett suddigt foto bär sann GEOMETRI men osann DETALJ; golvet låter
#: det säga det det vet och tiga om resten.
BLUR_WEIGHT_FLOOR = 0.2


@dataclass
class Keyframe:
    """Ett foto med känd placering, precis som ``Model/Keyframe.swift``."""

    id: int
    camera_from_world: np.ndarray  # 4×4
    intrinsics: np.ndarray  # 3×3
    image_size: np.ndarray  # (bredd, höjd) i pixlar
    depth_size: np.ndarray  # (bredd, höjd), 0 när LiDAR-djup saknas

    image: np.ndarray  # (höjd, bredd, 3) uint8
    depth: np.ndarray | None  # (höjd, bredd) float32, meter

    @property
    def position(self) -> np.ndarray:
        return np.linalg.inv(self.camera_from_world)[:3, 3]

    def project(self, points: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Världspunkter → pixelkoordinater och avstånd rakt framåt.

        ARKits kamerarum har Y uppåt och Z bakåt medan ``intrinsics`` räknar med
        hålkamerakonventionen (Y nedåt, Z framåt). Därför byter två tecken plats
        innan projektionen — samma korrigering som i Swift.
        """
        homogeneous = np.concatenate(
            [points, np.ones((len(points), 1), np.float32)], axis=1)
        camera = homogeneous @ self.camera_from_world.T
        depth = -camera[:, 2]

        pinhole = np.stack([camera[:, 0], -camera[:, 1], depth], axis=1)
        image = pinhole @ self.intrinsics.T
        with np.errstate(divide="ignore", invalid="ignore"):
            pixels = image[:, :2] / image[:, 2:3]
        return pixels, depth


@dataclass
class ScanBundle:
    mesh: SceneMesh
    keyframes: list[Keyframe]

    @classmethod
    def load(cls, directory: Path) -> "ScanBundle":
        mesh_path = directory / "room.mesh"
        if not mesh_path.exists():
            raise FileNotFoundError(
                "room.mesh saknas — skanningen fångade ingen tät yta")

        mesh = SceneMesh.decode(mesh_path.read_bytes())
        keyframes_path = directory / "keyframes.json"
        stored = json.loads(keyframes_path.read_text()) if keyframes_path.exists() else []

        keyframes = [frame for frame in (cls._keyframe(entry, directory)
                                         for entry in stored) if frame is not None]
        return cls(mesh, keyframes)

    @staticmethod
    def _keyframe(entry: dict, directory: Path) -> Keyframe | None:
        identifier = int(entry["id"])
        image_path = directory / f"kf{identifier}.jpg"
        if not image_path.exists():
            return None

        image = np.asarray(Image.open(image_path).convert("RGB"))
        image_size = np.asarray(entry["imageSize"], np.float32)
        depth_size = np.asarray(entry["depthSize"], np.int32)

        depth = None
        depth_path = directory / f"kf{identifier}.depth"
        if depth_path.exists() and depth_size.prod() > 0:
            raw = np.frombuffer(depth_path.read_bytes(), np.float32)
            if raw.size == depth_size.prod():
                depth = raw.reshape(int(depth_size[1]), int(depth_size[0])).copy()

        # Swift kodar matriserna kolumnvis; numpy vill ha dem radvis.
        camera_from_world = np.asarray(entry["cameraFromWorldColumns"], np.float32).T
        intrinsics = np.asarray(entry["intrinsicsColumns"], np.float32).T

        return Keyframe(id=identifier,
                        camera_from_world=camera_from_world,
                        intrinsics=intrinsics,
                        image_size=image_size,
                        depth_size=depth_size,
                        image=image,
                        depth=depth)


def connected_surface(mesh: SceneMesh) -> tuple[np.ndarray, np.ndarray]:
    """Skanningens yta utan de flagor som hänger fritt i luften.

    Ligger här och inte i ``pipeline`` för att både bakningen och splatten
    behöver den, och för att skillnaden syns tydligast i splatten: en gaussare
    som sitter på en flaga är brus mitt i rummet som inget straff kan nå, för
    den sitter ju på "ytan". Bakningen kastade flagorna redan innan; splatten
    sådde på dem.

    Delar bedöms på area och inte på antal trianglar: LiDAR-nätet är tätare nära
    kameran, så en handflatestor flaga tagen på en meters håll kan ha fler
    trianglar än en hel vägg sedd från andra sidan rummet.
    """
    import trimesh

    if mesh.is_empty:
        return mesh.positions, mesh.indices

    surface = trimesh.Trimesh(vertices=mesh.positions, faces=mesh.indices, process=True)
    surface.update_faces(surface.nondegenerate_faces())
    surface.remove_unreferenced_vertices()

    pieces = surface.split(only_watertight=False)
    if len(pieces) > 1:
        largest = max(piece.area for piece in pieces)
        kept = [piece for piece in pieces
                if piece.area > largest * LOOSE_PIECE_FRACTION]
        if kept:
            surface = trimesh.util.concatenate(kept)

    return (np.asarray(surface.vertices, np.float32),
            np.asarray(surface.faces, np.uint32))


def _grey(image: np.ndarray) -> np.ndarray:
    """Samma luma som Pillows ``convert("L")``, så talen går att jämföra."""
    if image.ndim == 2:
        return np.asarray(image, np.float64) / 255.0
    return np.asarray(image, np.float64) @ np.array([0.299, 0.587, 0.114]) / 255.0


def blur(grey: np.ndarray) -> float:
    """Crete-Roffets referensfria oskärpa i [0, 1], där högre är suddigare.

    Bilden suddas med en känd kärna och man mäter hur mycket grannskillnaderna
    FÖRÄNDRAS: en redan suddig bild ändras nästan inte, en skarp mycket. Måttet
    är kontrastoberoende, vilket är hela poängen — talen ska gå att jämföra
    mellan vår skanning och främmande dataset med annan kamera och exponering.

    ``grey`` är gråskala i [0, 1]. Kärnan är fast i pixlar, så två bilder måste
    ha samma upplösning för att gå att jämföra.
    """
    from scipy.ndimage import uniform_filter1d

    scores = []
    for image in (grey, grey.T):
        # Suddar bara i det led vi sedan mäter i, annars blandas riktningarna
        # ihop och ett foto med rörelseoskärpa åt ETT håll ser halvbra ut.
        blurred = uniform_filter1d(image, BLUR_SPAN, axis=1,
                                   mode="constant", cval=0.0)
        sharp_step = np.abs(np.diff(image, axis=1))
        blurred_step = np.abs(np.diff(blurred, axis=1))
        # Där suddningen SÄNKTE steget fanns skärpa att förlora.
        total = sharp_step.sum()
        lost = np.maximum(0.0, sharp_step - blurred_step).sum()
        scores.append(1.0 - lost / total if total > 0 else 1.0)
    # Värsta ledet bestämmer: rörelseoskärpa sitter i rörelseriktningen.
    return float(max(scores))


def sharpness_weights(keyframes) -> np.ndarray:
    """Hur mycket varje foto ska få bestämma, efter hur skarpt det är.

    Träningen tror lika mycket på varje foto. Ett foto taget mitt i en sväng
    lär då modellen att tavelramar ÄR smetar, och det syns som mjuka kanter i
    renderingen hur bra allt annat än blir. Vikten låter det fotot bidra med
    geometri och täckning utan att bestämma detaljen.

    Vikterna normeras till medelvärde ett. Annars sjunker den sammanlagda
    gradienten och ändringen blir i praktiken också en sänkt inlärningstakt —
    två ändringar i en, och ingen av dem går då att mäta för sig.
    """
    values = np.array([blur(_grey(frame.image)) for frame in keyframes])

    span = max(TOO_BLURRY - SHARP_ENOUGH, 1e-6)
    sharp = np.clip((TOO_BLURRY - values) / span, 0.0, 1.0)
    weights = BLUR_WEIGHT_FLOOR + (1.0 - BLUR_WEIGHT_FLOOR) * sharp
    return weights / weights.mean()


def agreement(points: np.ndarray, keyframes,
              margin: float = FREE_SPACE_MARGIN) -> np.ndarray:
    """Andelen foton som ser en yta där punkten ligger, av dem som har en åsikt.

    Ett foto kan säga tre saker om en punkt. Ligger djupkartans yta längre bort
    än punkten har kameran sett RAKT IGENOM den — punkten kan inte finnas.
    Ligger den inom marginalen är det samma yta, och fotot är ett vittne.
    Ligger den närmare står något i vägen och fotot vet ingenting.

    Punkter som inget foto har en åsikt om får 1,0. Frånvaro av bevis är inte
    bevis: en punkt strax utanför alla bildrutor ska inte städas bort.
    """
    witnesses = np.zeros(len(points), np.int32)
    contradictions = np.zeros(len(points), np.int32)

    for keyframe in keyframes:
        if keyframe.depth is None:
            continue
        depth_map = keyframe.depth
        height, width = depth_map.shape

        pixels, distance = keyframe.project(points)
        # Djupkartan är grövre än fotot medan ``intrinsics`` gäller fotot.
        scale = np.array([width, height]) / keyframe.image_size
        with np.errstate(invalid="ignore"):
            grid = np.nan_to_num(pixels * scale, nan=-1.0,
                                 posinf=-1.0, neginf=-1.0).astype(np.int64)

        inside = ((distance > 0.05) & (grid[:, 0] >= 0) & (grid[:, 0] < width)
                  & (grid[:, 1] >= 0) & (grid[:, 1] < height))
        index = np.nonzero(inside)[0]
        if len(index) == 0:
            continue

        seen = depth_map[grid[index, 1], grid[index, 0]]
        measured = seen > 0.05
        index, seen = index[measured], seen[measured]
        ahead = distance[index]

        witnesses[index[np.abs(seen - ahead) <= margin]] += 1
        contradictions[index[seen > ahead + margin]] += 1

    opinions = witnesses + contradictions
    return np.where(opinions > 0, witnesses / np.maximum(opinions, 1), 1.0)


def measured_points(keyframes, voxel: float = 0.01,
                    maximum_distance: float = 5.0,
                    minimum_agreement: float = MINIMUM_AGREEMENT) -> np.ndarray:
    """Varje LiDAR-djuppixel utfälld i världen, glesad till ett rutnät.

    Meshen är ARKits *rekonstruktion* och tappar det som är tunt, blankt eller
    rörligt — gardiner, krukväxter, soffkanter. Djupkartorna är mätningen den
    byggdes av och har kvar dem: mätt saknar nio procent av de rutor LiDAR såg
    en yta i meshen, och renderingsfelet är 2,4 gånger högre just där.

    Det spelar roll för att splatten klämmer varje gaussare mot närmaste
    ytpunkt. Där ytan saknas finns ingen laglig plats för det fotot ser, så
    färgen smetas ut på väggen bakom och blir den vita frosten. Punkterna här
    är inte gissade utan mätta, till skillnad från att flytta på spärren.

    Glesningen är inte bara för farten: trehundra foton som överlappar ger
    samma vägg om och om igen, och ett rutnät på en centimeter — i storlek med
    ``MAXIMUM_DRIFT`` — tappar ingenting spärren kan skilja på.

    Men LiDAR ljuger också, genom fönster och speglingar: 3,7 % av punkterna
    hamnar mer än 25 cm från varje yta, nästan alla INNE i rummet. Där ger de
    flygarna en laglig plats att stå på, och det är den vita slöjan. De rensas
    på ENIGHET och inte på avstånd till meshen — en gardin ligger också långt
    från meshen, men den har vittnen.
    """
    clouds = []
    for keyframe in keyframes:
        if keyframe.depth is None:
            continue
        depth = keyframe.depth
        rows, columns = np.nonzero((depth > 0.05) & (depth < maximum_distance))
        if len(rows) == 0:
            continue
        distance = depth[rows, columns].astype(np.float32)

        # Djupkartan är grövre än fotot medan ``intrinsics`` gäller fotot, så
        # pixeln räknas om till fotots upplösning — mitt i sin djupruta.
        scale = keyframe.image_size / np.array([depth.shape[1], depth.shape[0]])
        pixels = (np.stack([columns, rows], axis=1) + 0.5) * scale

        homogeneous = np.concatenate(
            [pixels, np.ones((len(pixels), 1), np.float32)], axis=1) * distance[:, None]
        pinhole = homogeneous @ np.linalg.inv(keyframe.intrinsics).T
        # Tillbaka från hålkameran till ARKits kamerarum: Y upp, Z bak.
        camera = np.stack([pinhole[:, 0], -pinhole[:, 1], -distance,
                           np.ones(len(pinhole), np.float32)], axis=1)
        clouds.append((camera @ np.linalg.inv(keyframe.camera_from_world).T)[:, :3])

    if not clouds:
        return np.zeros((0, 3), np.float32)

    points = np.concatenate(clouds).astype(np.float32)
    _, unique = np.unique(np.floor(points / voxel).astype(np.int64),
                          axis=0, return_index=True)
    points = points[unique]

    if minimum_agreement <= 0:
        return points
    return points[agreement(points, keyframes) >= minimum_agreement]
