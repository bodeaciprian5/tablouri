# Painting Scan – iPhone / iPad LiDAR capture for Gaussian Splatting (v0.3)

Captures a painting as a **production-ready Gaussian Splatting dataset** with camera poses straight from
ARKit and LiDAR – **no COLMAP / SfM step needed**. Export opens directly in PostShot, LichtFeld Studio,
Nerfstudio, gsplat and Brush.

## What's new in 0.3
- **iPhone layout**: on iPhone (landscape only) every panel is smaller, the camera strip scrolls sideways,
  and the preview window starts hidden (turn it on from the left rail).
- Supported LiDAR devices: iPhone 12 Pro / Pro Max or later, iPad Pro 2020 or later.
  Devices without LiDAR (iPad Air, non-Pro iPhones) record photos + poses only.

## What was new in 0.2
1. **Export for PostShot / LichtFeld Studio** – COLMAP `sparse/0` (cameras, images, points3D, in both
   .bin and .txt) built from ARKit poses + LiDAR points, plus Nerfstudio `transforms.json` and `sparse_pc.ply`.
2. **Projects with multiple scans** – every scan in a project shares one coordinate system (saved AR world
   map + relocalization), up to **1 million points per scan**, merged into one dataset on export.
3. **Live points + history points** – LiDAR points of the current scan (real colours) and of earlier scans
   (blue) are drawn over the camera view, plus green markers where frames were taken.
4. **Pro camera controls** – AUTO / LOCK / MANUAL with shutter, ISO, EV, white balance (Kelvin), tint and
   focus lock (AF-L).
5. **Motion gate** – speed gauge, "too fast" / "tracking jump" / "tracking lost" warnings with haptics;
   frames are skipped while moving too fast and for a moment after tracking recovers.
   Depth range now **0.05 m – 10 m**.
6. **Preview window** – the last saved frame and its colour-coded depth map, exactly as written to the dataset.

## Screen layout
| Area | Contents |
|---|---|
| Top | Project picker · tracking pill · warning pill · REC · video format · LiDAR badge |
| Left rail | Live points · history points · camera markers · preview window · depth range · settings |
| Right | Frames · points (1M budget bar) · scans · skipped frames · speed gauge · record button |
| Bottom | Camera strip: AUTO / LOCK / MANUAL · S · ISO · EV · WB · TINT · AF (tap a value for its slider) |

## Requirements
- Mac with **Xcode 15+**; iPad Pro (2020 or later) or iPhone 12 Pro or later for LiDAR; iPadOS/iOS **17+**.
- A free Apple ID is enough to run it on your own device (re-install every 7 days; a paid account removes that).

## Set up the project
### Option A – XcodeGen (fastest)
```bash
brew install xcodegen
cd PaintingScan
xcodegen generate
open PaintingScan.xcodeproj
```
### Option B – manually in Xcode
1. File › New › Project › iOS › **App** (SwiftUI, Swift), name `PaintingScan`.
2. Delete the generated `ContentView.swift` and `PaintingScanApp.swift`; drag in all files from `PaintingScan/`.
3. Minimum Deployments: iOS 17.0.
4. Info: `Privacy - Camera Usage Description`, `Application supports iTunes file sharing` = YES,
   `Supports opening documents in place` = YES, `Required device capabilities` → `arkit`.

### Run on your iPad
1. Connect the iPad and select it as run destination.
2. Signing & Capabilities: automatic signing, your Team, a unique bundle id (e.g. `com.yourname.paintingscan`).
3. iPad: Settings › Privacy & Security › **Developer Mode** on (first time).
4. Run (⌘R); trust the developer in Settings › General › VPN & Device Management.

## Scanning workflow
1. Light the painting evenly; avoid reflections on varnish.
2. Wait for the green **Tracking** pill. In the camera strip choose **LOCK** (or **MANUAL** and set
   S / ISO / WB yourself). Optionally tap **AF** → **AF-L** at your working distance.
3. Use the ruler button to set the depth range (e.g. near 0.10 m, far just behind the wall).
4. Press record and sweep slowly – keep the speed gauge green:
   horizontal arc at ~60 cm, vertical arc, then closer passes and oblique angles for brush-stroke relief.
5. Stop. Press record again for another pass – the earlier scan stays visible in blue so you can see gaps.
6. Next day / after closing the app: open the project, aim at the painting until **Relocalized** appears,
   then continue scanning in the same coordinate system.

## Export & training
Projects › your project › **Export for PostShot / LichtFeld Studio / Nerfstudio** → share the zip (AirDrop,
Files…). The `Export` folder is also in the Files app (*On My iPad › Painting Scan › Projects › … › Export*).

```
Export/
  images/s01_frame_00000.jpg …
  sparse/0/cameras.bin|txt, images.bin|txt, points3D.bin|txt   ← COLMAP model (from ARKit + LiDAR)
  transforms.json                                              ← Nerfstudio
  sparse_pc.ply                                                ← merged LiDAR point cloud
  depth/ (16-bit mm), confidence/
```
- **PostShot / LichtFeld Studio / Brush:** import the `Export` folder as a COLMAP dataset (images + sparse/0).
- **Nerfstudio:** `ns-train splatfacto --data Export` (uses `transforms.json` and `sparse_pc.ply`).

## Project files on the device
```
Projects/<name>/
  worldmap.arworldmap      shared AR coordinate system
  Scans/Scan_001/          images/, depth/, confidence/, frames.json, points.ply
  Export/                  created by Export
```

## Known limitations / next steps
- Not yet compiled against a device – expect a few compiler fixes on the first build.
- Images are stored in the sensor's landscape orientation (intrinsics match; training tools handle this).
- Next: on-device pose refinement, coverage heat-map on the painting plane, raking-light (photometric stereo)
  mode for relief, cloud training + in-app splat viewer, colour-checker calibration.

## No Mac? Build on GitHub and install from Windows
1. Create a free account on github.com › **New repository** (public = unlimited free build minutes).
2. **Upload files**: drag in everything inside this `PaintingScan` folder (project.yml, README.md,
   the `PaintingScan` source folder and the `.github` folder) and commit.
3. Open the **Actions** tab › *Build iPhone app*. It runs automatically (about 5–10 minutes).
4. When it shows a green tick, open the run and download **PaintingScan-ipa** (unzip it to get `PaintingScan.ipa`).
   If it fails, download **build-log** – it contains the compiler errors to fix.
5. On Windows install **iTunes** (the apple.com version, not the Microsoft Store one) and **Sideloadly** (sideloadly.io).
6. Connect the iPhone by cable, tap Trust, open Sideloadly, drag in `PaintingScan.ipa`, enter your Apple ID, Start.
7. iPhone: Settings › Privacy & Security › **Developer Mode** on (restart), then
   Settings › General › VPN & Device Management › trust your Apple ID.
With a free Apple ID the app must be re-installed every 7 days (Sideloadly can auto-refresh over Wi-Fi).
