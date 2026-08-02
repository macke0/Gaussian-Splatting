# Bakningsservern

Telefonen skannar och mäter. Den här servern målar.

Appen får två saker ur en skanning: en tät LiDAR-yta med rummets verkliga former,
och ett par hundra foton med känd kameraplacering. Var för sig är de inte mycket
att visa — ytan är grå, fotona är platta. Servern väver ihop dem till en
texturatlas och skickar tillbaka `baked.mesh` + `baked.png`, som RealityKit ritar
med `UnlitMaterial`.

**Måtten kommer aldrig härifrån.** De räknas ur `CapturedRoom` och `Measurement/`
i appen, på oförändrad data. Det som bakas är bara den yta rummet *visas* med.
Utjämningen och utglesningen i `pipeline.py` får därför runda av hörn — de
påverkar ingen nisch och ingen zon.

## Så här hänger det ihop

```
room.mesh + keyframes.json + kfN.jpg/.depth
  │
  ├─ bundle.py    läser mappen som den ligger, transponerar Swifts kolumnvisa matriser
  ├─ pipeline.py  slår ihop dubbletter, kastar flagor, jämnar ut (Taubin), glesar ut
  ├─ atlas.py     veckar ut ytan med xatlas och rasteriserar varje texel till en
  │               världspunkt + normal
  ├─ bake.py      projicerar varje texel in i varje foto, viktar och blandar
  └─ mesh.py      skriver SFTEX001, samma format som Model/TexturedMesh.swift läser
```

Ordningen är inte godtycklig: ytan städas *innan* den veckas ut, så att
utvecklingen slipper LiDAR:ns brus och atlasen rymmer trianglarna. Färgen läggs
på sist, när varje texel vet var i rummet den ligger.

### Varför blandning per texel och inte ett foto per triangel

Att välja det bästa fotot per triangel är enklare, men då syns varje
exponeringsskillnad som en söm mitt på väggen. Här bidrar alla foton som ser en
texel, viktade med `facing² / avstånd`. Texlar som inget foto såg blir grå och
fylls ut från sina grannar.

Djupkartan används för skymningstest: ser fotot något närmare än texeln är den
skymd. Djup `0` betyder att LiDAR inte nådde dit, inte att något står i vägen.

### Var gaussian splatting kopplas in

Färgkällan sitter isolerad i `bake.py`. Ett tränat splat skulle rendera texelns
världspunkt i stället för att slå upp den i fotona — allt annat (utveckling,
texel→värld, skymningstest, atlasskrivning) är identiskt. Det är därför den
enklare blandningen är byggd först: hela rundturen telefon → server → telefon går
att verifiera innan ett träningssteg läggs till.

## Köra

Python 3.10 eller nyare. På 3.9 hoppas utglesningen över med en varning —
resultatet blir samma bild, bara en större fil.

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest tests -q
```

Bara bakningen, utan HTTP:

```bash
.venv/bin/python -m spatialfit_server ~/rum/ABC123 --output ~/rum/ABC123
```

Servern:

```bash
.venv/bin/python -m uvicorn spatialfit_server.service:app --host 0.0.0.0 --port 8000
```

Ett jobb i taget. Bakningen är minnestung och två parallella tar inte halva
tiden — de tar dubbelt så mycket RAM.

### På en maskin med GPU

Ingenting i pipen kräver CUDA i dag; xatlas och trimesh är CPU-bundna. GPU:n
börjar spela roll först när splatting kopplas in. Kör över SSH:

```bash
ssh maskinen
tmux new -s bake
cd ~/spatialfit/server && .venv/bin/python -m uvicorn spatialfit_server.service:app --host 0.0.0.0 --port 8000
```

Öppna inte porten mot internet. Det finns ingen autentisering, och uppladdningen
packar upp ett zip-arkiv.

## Protokollet

| | |
|---|---|
| `POST /bake` | multipart-fält `scan`, ett zip av rummets mapp → `{"id", "status"}` |
| `GET /bake/{id}` | `{"status", "detail", "seenFraction", "triangleCount"}` |
| `GET /bake/{id}/mesh` | `baked.mesh` |
| `GET /bake/{id}/texture` | `baked.png` |

`status` är `pending`, `running`, `done` eller `failed`. Vid `failed` står orsaken
i `detail` — den ska nå telefonen, inte bara loggen.

Två raka nedladdningar i stället för ett arkiv: iOS kan packa ihop en mapp utan
beroenden (`NSFileCoordinator` `.forUploading`), men inte packa upp en.

Jobben ligger i minnet. Servern är ett verktyg för en maskin i ett rum, inte en
molntjänst — dör den är snabbaste vägen framåt att skicka upp skanningen igen.

Uppladdningen packas upp platt, bara filnamnet behålls. Ett zip-arkiv får inte
skriva utanför sin mapp.

## Filformaten

Båda är handskrivna och binära, med samma avkodare i Swift och Python.
`mesh.py` speglar `Model/SceneMesh.swift` och `Model/TexturedMesh.swift` — ändras
det ena måste det andra ändras i samma commit, annars går rummet sönder tyst.

**`SFMESH01`** (upp): magi, `uint32` hörn, `uint32` index, positioner (3×f32),
index (u32). Allt little-endian.

**`SFTEX001`** (ner): samma huvud, sedan positioner, normaler (3×f32) och
texturkoordinater (2×f32) per hörn, därefter indexen. 32 byte per hörn.

`keyframes.json` kommer ur Swifts `JSONEncoder`: SIMD-typer blir listor och
matriser är kolumnvisa, därför transponeras de i `bundle.py`. Djupkartorna är rå
`Float32`, radvis, tätt packade.
