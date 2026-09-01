"""Tränar samma rum med olika kromatak och mäter kornet, inte bara färgen.

Kromaklämman kom in för att brun parkett renderades grön. Den lyckades med
det — men skärpetalet gick från 90 % till 104 % och kornet ligger på 4,8 gånger
fotots. Över hundra procent är korn, inte skärpa, så misstanken är att felet
bara bytt kanal: klämman tvingar ihop grannarnas kroma, och modellen lägger
skillnaden i ljusheten i stället.

Det här svepet tränar av med klämman och med den, så att kornet kan mätas mot
färgen i stället för att gissas.

    python tools/kornsvep.py <skanningsmapp> [kromatak ...]
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server import splat as splat_module  # noqa: E402
from spatialfit_server.bundle import ScanBundle  # noqa: E402

ROOM = Path(sys.argv[1])
CAPS = [float(argument) for argument in sys.argv[2:]] or [0.0, 0.005]

logging.basicConfig(level=logging.INFO, format="%(message)s")
bundle = ScanBundle.load(ROOM)

for cap in CAPS:
    splat_module.MAXIMUM_CHROMA = cap
    model = splat_module.train(bundle)
    destination = Path(f"/tmp/korn-{cap:.3f}.spz")
    splat_module.write_spz(model, destination)
    print(f"KLAR kroma {cap:.3f} -> {destination}", flush=True)
