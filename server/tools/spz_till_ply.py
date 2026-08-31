"""Skriver om en SPZ till PLY, så telefonens EGEN fil går att öppna i en visare.

Poängen är att ta bort ett led ur felsökningen. En PLY sparad vid sidan av
bakningen är en GRANNE till det telefonen fick, inte samma fil: den är skriven
före kvantiseringen och kan i värsta fall komma ur en annan körning. Går man i
stället baklänges genom ``read_spz`` är det bevisligen samma byte som låg på
telefonen — ser den bra ut i SuperSplat sitter felet i vår renderare, ser den
lika dålig ut sitter det i bakningen.

    python tools/spz_till_ply.py <splat.spz> <ut.ply>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.splat import write_ply  # noqa: E402
from splat_check import read_spz  # noqa: E402

if __name__ == "__main__":
    model = read_spz(Path(sys.argv[1]))
    bands = model.colors.shape[1] - 1 if model.colors.ndim == 3 else 0
    print(f"SH-grad {round((bands + 1) ** 0.5) - 1}, {bands} band")
    write_ply(model, sys.argv[2])
