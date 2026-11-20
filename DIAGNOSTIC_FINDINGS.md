# VCam iOS 18.3.2 diagnostic handoff

## Verified in this workspace (2026-11-21)

- The current fork source still hooks `BWNodeOutput emitSampleBuffer:` in `Tweak.x` and filters both `mediaserverd` and `cameracaptured` in `vcam.plist`.
- The menu's diagnostic view read only the `mediaserverd` status. It could show `NO HEARTBEAT from mediaserverd` even if `cameracaptured` was alive and publishing a heartbeat.
- Runtime status depended on a plist under `/tmp/VCamStatus`. A sandbox denial could hide successful constructor, hook, or frame progress from the menu. The original code also tried to set the directory mode to `0777`.
- The existing `iproxy` listener and pinned SSH key are present on the Mac, but this agent's terminal sandbox rejects connections to `127.0.0.1:2222` with `Operation not permitted`. This is an environment restriction, not a measured iPhone SSH failure.
- Theos is absent locally, and the same sandbox cannot resolve `github.com` for `git clone`. The connected GitHub API was used to read the fork source.

## Changes in 0.1.35-diag1

- Added a Darwin notification stage bitmap for constructor, CMCapture load, class, selector, hook, first frame, media load, and first render. This survives failure to write the supplementary plist.
- The menu now selects an alive `cameracaptured` status first, then an alive `mediaserverd` status. It displays each stage independently.
- Removed the `0777` runtime status directory mode. File writes remain best effort; stage bitmap and heartbeat carry the cross-sandbox minimum.
- Added `scripts/diagnose-local.sh`, a read-only Mac Terminal probe that verifies the remote iOS shell, saves the installed tweak files, checks plist and Mach-O metadata, and collects a short filtered syslog sample.

## What remains unproven

The actual device has not been contacted from this sandbox. Therefore the initial injection failure, `BWNodeOutput` availability, frame path, media access, and image or video replacement have **not** been established. A successful CI build would prove only compilation and packaging. Do not install this diagnostic revision as a camera fix without a rollback copy of the installed package and a controlled test.

## Next evidence gate

Run `bash scripts/diagnose-local.sh` from this fork's directory inside `/Users/aleksandr/Projects/iPhone11JB` in a normal Mac Terminal with the phone connected and Camera open during the 20-second log window. The output stays under the parent project's ignored, private `data/` directory. Compare the installed binary and filter with this branch. If a diagnostic build is installed, read the menu's `Stages` line to distinguish injection, hook, frame, and render failures before changing the capture backend.

## Related upstream reports

- Dopamine issue [#948](https://github.com/opa334/Dopamine/issues/948) reports absent tweak injection on an iPhone 11 with iOS 18.5, but has no confirmed fix in its comments.
- Dopamine issue [#974](https://github.com/opa334/Dopamine/issues/974) reports a similar symptom on iPhone 11 with iOS 18.3.2; it has no resolution as of this review.

These reports are possible leads, not proof of the cause on this device.

## Rollback for a later controlled install

Before installing a diagnostic build, retain the known-working `0.1.34` package or a package-manager download. If the camera daemon crashes after installation, disable Tweak Injection through Dopamine, remove `0.1.35-diag1` through Sileo/Zebra, then reinstall `0.1.34` and re-enable injection. Do not repeatedly restart a crashing camera service to collect more data.
