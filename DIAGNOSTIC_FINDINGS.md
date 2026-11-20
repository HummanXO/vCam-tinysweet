# VCam on iPhone 11, iOS 18.3.2 — device findings

## Current state (2026-11-21)

- `0.1.35-diag7` rootless is installed on the iPhone. Its CI build passed; the package was checked by SHA-256 before installation.
- With a photo selected, `cameracaptured` reports all stages: constructor, CMCapture, class, selector, hook, camera frames, media loaded, and replacement rendered. The camera daemon remained at the same PID for at least 12 seconds after the final test.
- The current selected photo is in `/var/jb/var/mobile/VCam/Media`, the persistent jailbreak path used for new imports. The earlier selection under `/var/jb/tmp/VCamMedia` was copied there without exposing its contents.
- A screen capture could not be obtained because iOS rejected the `screenshotr` service without a mounted Developer disk image. The image change has been verified at the internal render stage, not by inspecting the visible Camera preview.

## Root cause of the photo failure

- The original menu checked only `mediaserverd`, while iOS 18 uses `cameracaptured` for this camera path.
- The tweak was injected and hooked `BWNodeOutput emitSampleBuffer:`. Live logs showed 2304x1728 buffers reaching the hook.
- `cameracaptured` denied file access under `/tmp` and `/var/mobile/Media/VCam/Media` with `EPERM`. The same synthetic PNG loaded and rendered from `/var/jb/tmp`, then from persistent `/var/jb/var/mobile/VCam/Media`.
- `/tmp/VCamStatus` also returned `EPERM`; the old code logged about 3900 errors in 20 seconds. The current code keeps status in memory, uses Darwin notifications for cross-process stages, and retries the denied directory only every 30 seconds.

## Video limitation

- A readable synthetic H.264 MP4 caused an uncaught exception at `-[AVPlayerItem addOutput:]` in the older build. The 0.1.35-diag7 guard prevents the camera daemon from crashing.
- Both the original and basic BGRA initialization of `AVPlayerItemVideoOutput` return `nil` inside `cameracaptured` on this device. The video file is readable, but no video frame is loaded or rendered. Video replacement requires another decode path; the test restored the selected photo afterward.

## Evidence and rollback

- Redacted device logs and package files remain under the parent project's private `data/` directory; no private media bytes were uploaded.
- The `0.1.34` rootless package is saved at `data/vcam-packages/rollback/vcam-rootless.deb`. The tested 0.1.35-diag7 package is at `data/vcam-packages/diag7/vcam-rootless.deb`.
- The pull request remains a draft while video replacement and visible preview verification are outstanding.
