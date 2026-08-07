"""Hämtar EN scen ur Inrias förtränade modeller utan att ladda ned alla 14,7 GB.

Servern svarar med ``Accept-Ranges: bytes``, och en zip har sin katalog i
slutet. Då räcker det att läsa katalogen och sedan just den post vi vill ha —
`zipfile` behöver bara något som går att söka i, inte en fil på disk.

Poängen med filen är att vara en ground truth: den är tränad av
referensimplementationen på en känd scen, så renderas den skarpt i vår app är
renderaren frikänd och det är vår indata som binder.
"""
import sys
import urllib.request
import zipfile
from pathlib import Path

URL = ("https://repo-sam.inria.fr/fungraph/3d-gaussian-splatting/"
       "datasets/pretrained/models.zip")
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/referens")
OUT.mkdir(exist_ok=True)


class RemoteFile:
    """Ett sökbart filobjekt över HTTP, precis så mycket som `zipfile` kräver."""

    def __init__(self, url):
        self.url = url
        self.offset = 0
        with urllib.request.urlopen(
                urllib.request.Request(url, method="HEAD")) as response:
            self.length = int(response.headers["Content-Length"])

    def seek(self, offset, whence=0):
        self.offset = (offset if whence == 0 else
                       self.offset + offset if whence == 1 else
                       self.length + offset)
        return self.offset

    def tell(self):
        return self.offset

    def read(self, size=-1):
        if size < 0:
            size = self.length - self.offset
        if size == 0:
            return b""
        last = min(self.offset + size, self.length) - 1
        request = urllib.request.Request(
            self.url, headers={"Range": f"bytes={self.offset}-{last}"})
        with urllib.request.urlopen(request) as response:
            data = response.read()
        self.offset += len(data)
        return data

    def seekable(self):
        return True


archive = zipfile.ZipFile(RemoteFile(URL))
clouds = [info for info in archive.infolist()
          if info.filename.endswith("point_cloud.ply")]
clouds.sort(key=lambda info: info.file_size)
for info in clouds:
    print(f"{info.file_size / 1e6:8.1f} MB  {info.filename.split('/')[0]}")

# Scennamnet som andra argument. `train` är ett FÖREMÅL man går runt, alltså
# raka motsatsen till ett rum: kameran tittar inåt mot mitten i stället för
# utåt mot väggarna. Vill man veta hur ett rum borde se ut är `drjohnson` och
# `playroom` de närmaste — riktiga rum, filmade inifrån precis som våra.
WANTED = sys.argv[2] if len(sys.argv) > 2 else None
chosen = next((info for info in clouds
               if info.filename.split("/")[0] == WANTED), clouds[0])
scene = chosen.filename.split("/")[0]
print(f"\nhämtar {chosen.filename} ({chosen.file_size / 1e6:.1f} MB)")
destination = OUT / "benchmark.ply"
with archive.open(chosen) as source, destination.open("wb") as target:
    while chunk := source.read(1 << 20):
        target.write(chunk)
print(f"skrev {destination} ({destination.stat().st_size / 1e6:.1f} MB)")

# Kamerorna är hälften av testet. Ur en fritt vald bana ser vilken splat som
# helst ut som färgat dis — den har bara blivit visad inifrån sina egna poser.
cameras = OUT / "benchmark-kameror.json"
cameras.write_bytes(archive.read(f"{scene}/cameras.json"))
print(f"skrev {cameras} ({cameras.stat().st_size / 1e3:.0f} kB)")
