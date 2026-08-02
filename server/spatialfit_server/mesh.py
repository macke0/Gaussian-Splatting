"""Binärformaten appen och servern delar.

Speglar ``SpatialFit/Model/SceneMesh.swift`` och
``SpatialFit/Model/TexturedMesh.swift``. Ändras det ena måste det andra följa
med — därför ligger magin och fältordningen samlade här och ingen annanstans.

Allt är little-endian. Hörnen är packade till 12 byte, inte de 16 en
``SIMD3<Float>`` upptar i minnet.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field

import numpy as np

SCENE_MAGIC = b"SFMESH01"
TEXTURED_MAGIC = b"SFTEX001"


class FormatError(ValueError):
    """Filen är inte det den utger sig för att vara, eller är avhuggen."""


@dataclass
class SceneMesh:
    """Den täta LiDAR-ytan som telefonen skannade."""

    positions: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.float32))
    indices: np.ndarray = field(default_factory=lambda: np.zeros((0, 3), np.uint32))

    @classmethod
    def decode(cls, data: bytes) -> "SceneMesh":
        if len(data) < 16 or data[:8] != SCENE_MAGIC:
            raise FormatError("inte en scenmesh")

        vertex_count, index_count = struct.unpack_from("<II", data, 8)
        if index_count % 3:
            raise FormatError("index går inte jämnt upp i trianglar")

        expected = 16 + vertex_count * 12 + index_count * 4
        if len(data) != expected:
            raise FormatError(f"väntade {expected} byte, fick {len(data)}")

        positions = np.frombuffer(data, np.float32, vertex_count * 3, 16)
        indices = np.frombuffer(data, np.uint32, index_count, 16 + vertex_count * 12)

        if index_count and indices.max() >= vertex_count:
            raise FormatError("index pekar utanför hörnlistan")

        return cls(positions.reshape(-1, 3).copy(), indices.reshape(-1, 3).copy())

    @property
    def is_empty(self) -> bool:
        return len(self.indices) == 0


@dataclass
class TexturedMesh:
    """Ytan efter bakning: normaler, UV och en atlas som täcker allt."""

    positions: np.ndarray
    normals: np.ndarray
    uvs: np.ndarray
    indices: np.ndarray

    def encode(self) -> bytes:
        vertex_count = len(self.positions)
        if not (len(self.normals) == len(self.uvs) == vertex_count):
            raise FormatError("olika många positioner, normaler och UV")

        flat = self.indices.reshape(-1).astype("<u4")
        if vertex_count and len(flat) and flat.max() >= vertex_count:
            raise FormatError("index pekar utanför hörnlistan")

        return b"".join([
            TEXTURED_MAGIC,
            struct.pack("<II", vertex_count, len(flat)),
            self.positions.astype("<f4").tobytes(),
            self.normals.astype("<f4").tobytes(),
            self.uvs.astype("<f4").tobytes(),
            flat.tobytes(),
        ])

    @classmethod
    def decode(cls, data: bytes) -> "TexturedMesh":
        """Behövs bara av testerna, men håller de två riktningarna ärliga."""
        if len(data) < 16 or data[:8] != TEXTURED_MAGIC:
            raise FormatError("inte en bakad mesh")

        vertex_count, index_count = struct.unpack_from("<II", data, 8)
        expected = 16 + vertex_count * 32 + index_count * 4
        if index_count % 3 or len(data) != expected:
            raise FormatError("avhuggen fil")

        offset = 16
        positions = np.frombuffer(data, np.float32, vertex_count * 3, offset)
        offset += vertex_count * 12
        normals = np.frombuffer(data, np.float32, vertex_count * 3, offset)
        offset += vertex_count * 12
        uvs = np.frombuffer(data, np.float32, vertex_count * 2, offset)
        offset += vertex_count * 8
        indices = np.frombuffer(data, np.uint32, index_count, offset)

        return cls(positions.reshape(-1, 3).copy(),
                   normals.reshape(-1, 3).copy(),
                   uvs.reshape(-1, 2).copy(),
                   indices.reshape(-1, 3).copy())
