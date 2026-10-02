# Gaussian Splatting — an experiment in splatting a room from a phone scan

An experiment in **3D Gaussian splatting**: take a LiDAR scan of a real room made with an iPhone, train a Gaussian splat of it on a GPU, ship it back to the phone, and render it there in real time with Metal.

It started as one feature of a larger app (SpatialFit, below). It turned into a measurement-driven investigation into one question: **how sharp can a splat of a room get when you already know where the walls are?**

It is unfinished, and it partly works. Close to where the photos were taken, the splat looks right. From other angles it still has haze, grain and softness. The open problems are written down in [`textur.md`](textur.md) rather than hidden.

> **Scope.** The splat is the *appearance* layer only. Measurements in the app come from LiDAR geometry, never from the splat. The trainer is [gsplat](https://github.com/nerfstudio-project/gsplat) and the on-phone rasterizer is [MetalSplatter](https://github.com/scier/MetalSplatter). The work in this repo is everything around them: capture, a LiDAR-constrained training loop, the file format, the loader, the colour-space fix, and the measurement tooling.

## Pipeline

```
iPhone (RoomPlan + ARKit)               GPU server (Python, CUDA)                 iPhone
┌──────────────────────────┐   zip   ┌──────────────────────────────────┐  .spz  ┌─────────────────────┐
│ keyframes + poses +      │ ──────▶ │ pose refinement (COLMAP, opt.)   │ ─────▶ │ streaming SPZ decode │
│ LiDAR depth + LiDAR mesh │         │ LiDAR-seeded splat training      │        │ MetalSplatter render │
└──────────────────────────┘         │ SPZ export                       │        │ + textured LiDAR mesh│
                                     └──────────────────────────────────┘        └─────────────────────┘
```

1. **Capture** ([`KeyframeRecorder.swift`](SpatialFit/ARKit/KeyframeRecorder.swift)). A keyframe is saved after 3 cm or 8° of movement, up to 900 frames. Each keeps the ARKit pose, camera intrinsics and the raw 256×192 LiDAR depth map. A sharpness gate drops blurry frames, and the LiDAR mesh is saved alongside.
2. **Poses.** ARKit poses by default. Optionally they are refined with COLMAP and aligned back to metric scale with an Umeyama fit. The refined poses are accepted only if reprojection error stays under 3 px. ARKit misses its own pixels by about 13 px median and COLMAP by about 0.8 px ([`poses.py`](server/spatialfit_server/poses.py)).
3. **Training** ([`splat.py`](server/spatialfit_server/splat.py)). gsplat with MCMC densification, spherical harmonics up to degree 3, 30,000 steps and a budget of up to 3 M Gaussians. The seeding and constraints are my own work, see below.
4. **Export.** A numpy writer for Niantic's SPZ format: 24-bit fixed-point positions, smallest-three quaternion packing and quantised SH. That is 20 bytes per Gaussian against 68 for PLY, so the phone can hold three times as many.
5. **On the phone** ([`SPZStream.swift`](SpatialFit/Splatting/SPZStream.swift), [`SplatRoomView.swift`](SpatialFit/Splatting/SplatRoomView.swift)). A hand-written streaming decoder feeds the splat in chunks. The splat is composited over the textured LiDAR mesh (see [`Backdrop.metal`](SpatialFit/Splatting/Backdrop.metal)) so holes in photo coverage show the mesh instead of nothing. There is also a first-person walk camera.

## What is different here: the room is not a blank slate

A normal splat starts from a sparse point cloud and has to work out where surfaces are. A phone with LiDAR already knows. This repo uses that:

- **LiDAR seeding.** One thin disc-shaped Gaussian per mesh vertex, oriented by the surface normal.
- **A surface clamp.** After every optimizer step, Gaussians are pulled back to within 2 cm of an anchor cloud. The cloud is the cleaned mesh plus every LiDAR depth pixel, unprojected and voxel-thinned (7.1 M points against 211 k from the mesh alone).
- **Per-photo exposure and white-balance correction.** Brightness varied 2.3× between the brightest and darkest photo in one scan.
- **Blur-weighted photos.** Sharp photos count for more in the loss.
- **Optional learned pose nudges**, with measured drift (11 mm median in the last run).

## Measurements

The most useful thing in the repo may be [`textur.md`](textur.md), a lab notebook of what was measured and what was ruled out. A few results from it:

| Question | Result |
|---|---|
| Why did the splat look like a pastel painting? | Sharpness is **Gaussians per square metre**. 16 neighbouring photos of one corner give 85 % of photo sharpness. The whole room with a similar Gaussian count (287,883) gives 40 %. |
| Does the surface clamp help? | L1 error says no (0.1361 clamped vs 0.1225 free). A fog metric says yes: **0.0 % vs 44.6 %** of mass off the surface. L1 rewards fog, so the clamp stays. |
| Does adding depth maps to the anchor surface help? | Empty pixels 9.0 % → 2.8 %, held-out sharpness 86.1 % → 90.1 %. |
| Why were the colours wrong on the phone? | MetalSplatter applies `pow(2.2)` before blending and gsplat trains with sRGB blending. Pre-compensating the colours and rescaling the SH bands by the gamma derivative fixed it (brightness 0.55 → 0.63). |
| Is the renderer correct? | Checked against the reference INRIA `train` scene (559,263 Gaussians, SH 3), which renders on the phone. |
| File size | 1.9 M Gaussians with SH 3: 60.7 MB as SPZ. |

Two rules the measurements taught, and which the tools enforce: never judge a splat from one number (L1 rewards blur and fog, sharpness rewards grain), and always compare a *trained* view with a *held-out* one. [`server/tools/`](server/tools) has a separate check for each failure mode (edge sharpness, grain, shell, chroma, coverage, view angle).

## Engineering notes

- **Memory.** The first SPZ loader guessed a decompressed size of 1.21 GB for a 60.7 MB file and the app was killed by iOS. The decoder now reads the gzip trailer for the exact size (125 MB) and streams in chunks. A 2 M-Gaussian scene went from 675 MB to 215 MB.
- **GPU memory.** Training photos are stored as `uint8` on the GPU instead of `float32`: 6.4 GB to 1.6 GB at 300 photos.
- **Benchmark harness.** [`fetch_benchmark.py`](server/tools/fetch_benchmark.py) pulls one reference scene out of a 14.7 GB zip using HTTP range requests. [`referens_skanning.py`](server/tools/referens_skanning.py) converts a COLMAP dataset into this project's scan format, to tell whether blur comes from the data or from the code.
- **Layering.** The Swift domain and engine layers import only `Foundation` and `simd`, and units are converted in one place. The binary mesh formats are mirrored between Swift and Python.

## Status

| | |
|---|---|
| Works | Capture, pose refinement, training, SPZ export and import, on-phone rendering, mesh composite, walk camera. Verified on a real scanned room and on INRIA reference scenes. |
| Open | A "frost" shell: about 78 % of the mass sits 5–20 mm in front of the wall, and the optimizer keeps pushing mass outward. Tightening the clamp was ruled out by measurement. The next idea, untried, is to make MCMC relocation pick destinations on the measured surface. |
| Tried and dropped | Gradient-driven densification (no gain), 2DGS, thickness caps (a blur source), SH degree 0. |
| Not built | Auth, multiple concurrent jobs. It is a tool for one machine and one room. |

## Parts

| | |
|---|---|
| **iOS app** | Swift / SwiftUI, RealityKit, RoomPlan, ARKit, Metal. About 10,300 lines including 102 tests. |
| **Server** | Python 3.10+, numpy, scipy, trimesh, FastAPI, pycolmap (optional), PyTorch and gsplat for training. About 6,700 lines including 66 tests. |
| **Tooling** | 21 measurement scripts in [`server/tools/`](server/tools). |

## Running it

Training needs an NVIDIA GPU (developed on an RTX 5090, CUDA 12.8+). Capturing needs an iPhone or iPad with LiDAR. No scan data is included in the repo.

```bash
# server
cd server
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m pytest tests -q

# GPU extras for splat training
.venv/bin/pip install torch --index-url https://download.pytorch.org/whl/cu128
.venv/bin/pip install ninja
.venv/bin/pip install --no-build-isolation --no-binary gsplat gsplat

# train a splat from a captured scan folder
.venv/bin/python tools/train_splat.py <scan-dir> --output room.spz

# serve it to the phone
.venv/bin/python -m uvicorn spatialfit_server.service:app --host 0.0.0.0 --port 8000
```

```bash
# iOS app (macOS, iOS 18 SDK)
xcodebuild -scheme SpatialFit -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## About SpatialFit

SpatialFit is a prototype iOS app for kitchen, bathroom and construction retailers. It checks whether a product fits a niche in a room, using a geometric collision engine with green, yellow and red zones. The aim is to cut returns caused by "it didn't fit". Gaussian splatting was added so the scanned room looks like the real room. Code comments and the notes in `textur.md` are mostly in Swedish.
