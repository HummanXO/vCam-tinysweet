# VCam iOS 18.3.2 diagnostic handoff

## Verified on the iPhone (2026-11-21)

- USB-forwarded SSH now works. The installed package was 0.1.34 during the first probe and 0.1.35-diag1 during the second; the latter's installed dylibs match the CI rootless package by SHA-256.
- `cameracaptured` loads `vcam.dylib`: the 20-second syslog windows each contained about 3900 messages from it. Every message was a permission denial while creating `/tmp/VCamStatus`. Injection is proven; hook, media loading, and rendering still need stage evidence.
- The selected image setting is enabled and points to `/tmp/VCamMedia/media-*.jpeg`, but `/tmp/VCamMedia` is absent from the mobile SSH filesystem view. This is a likely stale selection, though the camera daemon's filesystem view has not been proven identical.
- The diagnostic capture is under the parent project's private `data/vcam-diagnostic-20261121-013709/` directory. No private media bytes were uploaded.

## 0.1.35-diag2 candidate

- Keep in-memory status values in the camera daemon and retry a denied `/tmp/VCamStatus` directory only every 30 seconds. This prevents the per-frame log flood and repeated filesystem work.
- Import selected media into `/var/mobile/Media/VCam/Media` instead of `/tmp/VCamMedia`, alongside the persistent settings. A selection made before this change must be imported again through the menu.
- The persistent path is a hypothesis for media readability by `cameracaptured`; it still requires a device test. Keep the 0.1.34 rollback package available.

## Changes in 0.1.35-diag1

- Added a Darwin notification stage bitmap for constructor, CMCapture load, class, selector, hook, first frame, media load, and first render. This survives failure to write the supplementary plist.
- The menu now selects an alive `cameracaptured` status first, then an alive `mediaserverd` status. It displays each stage independently.
- Removed the `0777` runtime status directory mode. File writes remain best effort; stage bitmap and heartbeat carry the cross-sandbox minimum.
- Added `scripts/diagnose-local.sh`, a read-only Mac Terminal probe that verifies the remote iOS shell, saves the installed tweak files, checks plist and Mach-O metadata, and collects a short filtered syslog sample.

## What remains unproven

Injection into `cameracaptured` is established. `BWNodeOutput` hook installation, camera frames reaching it, media access, and image or video replacement have **not** been established. A successful CI build proves compilation and packaging only.

## Next evidence gate

Read the installed diagnostic menu's `Stages` line while Camera is open. On 0.1.35-diag2, import a fresh image through the menu, then inspect stages for hook, frames, media, and render. The private capture remains under the parent project's `data/` directory.

## Related upstream reports

- Dopamine issue [#948](https://github.com/opa334/Dopamine/issues/948) reports absent tweak injection on an iPhone 11 with iOS 18.5, but has no confirmed fix in its comments.
- Dopamine issue [#974](https://github.com/opa334/Dopamine/issues/974) reports a similar symptom on iPhone 11 with iOS 18.3.2; it has no resolution as of this review.

These reports are possible leads, not proof of the cause on this device.

## Rollback for a later controlled install

The `0.1.34` rootless and roothide packages have been saved in the parent project's private `data/vcam-packages/rollback/` directory. If the camera daemon crashes after a later install, disable Tweak Injection through Dopamine, remove the new package through Sileo/Zebra, then reinstall `0.1.34` and re-enable injection. Do not repeatedly restart a crashing camera service to collect more data.
