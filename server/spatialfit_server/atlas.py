"""Ytan veckas ut i planet och varje texel får veta var i rummet den ligger.

Det är hela skillnaden mot appens texturering. Där väljer varje triangel ett
foto, och skarven mellan två foton syns som ett hopp i exponering. Här får
varje texel i stället en egen världspunkt, och kan därför vägas ihop ur alla
bilder som såg just den punkten.

Utvecklingen görs med xatlas. Rasteriseringen är egen: den behöver lämna ifrån
sig position och normal per texel, inte färg, och det gör ingen färdig
rasterizer.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import xatlas


@dataclass
class Atlas:
    """Mesh med UV, plus vad varje texel motsvarar i rummet."""

    positions: np.ndarray  # (v, 3) hörn, uppdelade vid sömmarna
    normals: np.ndarray  # (v, 3)
    uvs: np.ndarray  # (v, 2) i [0, 1]
    indices: np.ndarray  # (f, 3)

    size: int

    texel_positions: np.ndarray  # (n, 3) världspunkt per täckt texel
    texel_normals: np.ndarray  # (n, 3)
    texel_rows: np.ndarray  # (n,) rad i atlasen
    texel_columns: np.ndarray  # (n,) kolumn i atlasen

    @property
    def coverage(self) -> float:
        return len(self.texel_positions) / float(self.size * self.size)


def unwrap(positions: np.ndarray, indices: np.ndarray) -> tuple[np.ndarray, ...]:
    """Vecka ut ytan. Hörn längs en söm dubbleras, därför nya listor."""
    mapping, faces, uvs = xatlas.parametrize(positions.astype(np.float32),
                                             indices.astype(np.uint32))
    return positions[mapping], uvs.astype(np.float32), faces.astype(np.uint32), mapping


def vertex_normals(positions: np.ndarray, indices: np.ndarray) -> np.ndarray:
    """Ytviktade hörnormaler. Kryssprodukten är dubbla arean, så stora
    trianglar väger tyngre av sig själva."""
    normals = np.zeros_like(positions)
    corners = positions[indices]
    face = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
    for column in range(3):
        np.add.at(normals, indices[:, column], face)

    lengths = np.linalg.norm(normals, axis=1, keepdims=True)
    return np.divide(normals, lengths, out=np.zeros_like(normals), where=lengths > 0)


def rasterize(positions: np.ndarray, normals: np.ndarray, uvs: np.ndarray,
              indices: np.ndarray, size: int) -> Atlas:
    """Fyller atlasen med världspunkter.

    Trianglarna gås igenom en och en, men bara över sin egen ruta i atlasen.
    Utvecklingen ger små trianglar, så rutorna är några texlar stora — det som
    ser ut som en loop över hundratusen trianglar är i praktiken en loop över
    lika många små numpy-operationer.
    """
    corners_uv = uvs[indices] * size
    corners_world = positions[indices]
    corners_normal = normals[indices]

    lower = np.floor(corners_uv.min(axis=1)).astype(np.int32)
    upper = np.ceil(corners_uv.max(axis=1)).astype(np.int32)
    np.clip(lower, 0, size - 1, out=lower)
    np.clip(upper, 0, size, out=upper)

    rows: list[np.ndarray] = []
    columns: list[np.ndarray] = []
    world: list[np.ndarray] = []
    facing: list[np.ndarray] = []

    for face in range(len(indices)):
        x0, y0 = lower[face]
        x1, y1 = upper[face]
        if x1 <= x0 or y1 <= y0:
            continue

        grid_x, grid_y = np.meshgrid(np.arange(x0, x1), np.arange(y0, y1))
        # Texelns mitt, inte dess hörn. Annars glider texturen en halv texel.
        points = np.stack([grid_x.ravel() + 0.5, grid_y.ravel() + 0.5], axis=1)

        weights = _barycentric(corners_uv[face], points)
        if weights is None:
            continue

        # En liten marginal utanför triangeln fyller sömmarna, som annars
        # lyser igenom som glipor när texturen filtreras.
        inside = weights.min(axis=1) > -0.5 / max(x1 - x0, y1 - y0, 1)
        if not inside.any():
            continue

        selected = weights[inside]
        rows.append(grid_y.ravel()[inside])
        columns.append(grid_x.ravel()[inside])
        world.append(selected @ corners_world[face])
        facing.append(selected @ corners_normal[face])

    if not rows:
        return Atlas(positions=positions, normals=normals, uvs=uvs, indices=indices,
                     size=size,
                     texel_positions=np.zeros((0, 3), np.float32),
                     texel_normals=np.zeros((0, 3), np.float32),
                     texel_rows=np.zeros((0,), np.int32),
                     texel_columns=np.zeros((0,), np.int32))

    texel_normals = np.concatenate(facing).astype(np.float32)
    lengths = np.linalg.norm(texel_normals, axis=1, keepdims=True)
    np.divide(texel_normals, lengths, out=texel_normals, where=lengths > 0)

    return Atlas(positions=positions, normals=normals, uvs=uvs, indices=indices,
                 size=size,
                 texel_positions=np.concatenate(world).astype(np.float32),
                 texel_normals=texel_normals,
                 texel_rows=np.concatenate(rows).astype(np.int32),
                 texel_columns=np.concatenate(columns).astype(np.int32))


def _barycentric(triangle: np.ndarray, points: np.ndarray) -> np.ndarray | None:
    """Barycentriska vikter, eller ``None`` för en triangel utan area."""
    a, b, c = triangle
    edge1 = b - a
    edge2 = c - a
    area = edge1[0] * edge2[1] - edge1[1] * edge2[0]
    if abs(area) < 1e-9:
        return None

    offset = points - a
    weight_b = (offset[:, 0] * edge2[1] - offset[:, 1] * edge2[0]) / area
    weight_c = (edge1[0] * offset[:, 1] - edge1[1] * offset[:, 0]) / area
    return np.stack([1.0 - weight_b - weight_c, weight_b, weight_c], axis=1)
