# VCam for iOS

**VCam** is an iOS virtual-camera replacement tweak by **tinysweet**. It lets you choose a photo or video from your media library and use that media in place of the live camera frames delivered through a compatible iOS camera capture pipeline.

VCam is intended for creative camera setups, LARP (live-action role-playing), character or scene role-play, pre-recorded camera scenes, livestream overlays, and other situations where you want a prepared visual source to appear as the camera input.

> VCam replaces frames in a compatible camera pipeline. It does not create a separate physical camera device, and compatibility depends on the app, iOS version, and camera capture path it uses.

## What VCam can do

### Use a photo as the camera source

- Select a photo from the iOS photo library.
- Import it into VCam's local media storage.
- Use the selected image as the replacement camera frame.
- Reposition, rotate, and zoom the image to fit the framing you need.

### Use a video as the camera source

- Select a video from the iOS photo library.
- VCam prepares the imported clip for camera playback, normalizing its orientation and converting it to a camera-friendly stream at up to 1080p / 30 FPS when supported, with 720p / 30 FPS as a fallback.
- The video is muted and automatically starts again from the beginning when it reaches the end, so the clip can repeat during a livestream or role-play session.
- Pause and resume the clip from the floating controls.
- Video frame extraction runs separately from the real-time camera callback. When camera frames stop arriving, VCam pauses video decoding to reduce unnecessary work and resumes when the camera pipeline becomes active again.

### LIVE OBS CAMERA (iOS 18.3.2 rootless)

VCam can use the current OBS scene as its camera image. OBS outputs H.264/MPEG-TS to a local UDP port on the Mac. `scripts/obs-relay.py` decodes it with FFmpeg (VideoToolbox when available), keeps only the latest frame, and sends JPEG frames over authenticated TCP to the separate iPhone receiver service. The camera hook does no networking or JPEG decoding: a background frame pump updates the image consumed by its existing render path. On disconnect, the last complete frame remains until replacement is disabled or another source is selected.

#### Setup on Mac and iPhone

For a landscape clip, start with MP4 (H.264), 1920×1080 or 1280×720, at 30 FPS. Set both the OBS canvas and output to a 16:9 resolution. In the source's transform menu, reset the transform and choose Fit to Screen. In LIVE OBS, use 1× zoom and reset position to see the whole frame. Different camera and OBS aspect ratios can produce black bars. Increasing zoom crops the edges.

1. Install the `0.1.36-live8` rootless package on the Dopamine iPhone. The receiver needs the jailbreak `python3` package and listens on TCP port `47110`. Keep Mac and iPhone on the same Wi-Fi network and allow this port through any local firewall.
2. On the Mac install FFmpeg (`brew install ffmpeg`). Connect the iPhone by USB once so the relay can securely fetch the receiver's random token using the project's pinned SSH helper. The token is cached in `iPhone11JB/data/vcam-obs-token.hex` with owner-only permissions. Later runs can use Wi-Fi alone.
3. In OBS set **Settings → Video → Output (Scaled) Resolution** to `1280×720` and **Common FPS Values** to `30`.
4. In **Settings → Output**, set **Output Mode: Advanced**. On the **Recording** tab set **Type: Custom Output (FFmpeg)**, **FFmpeg Output Type: Output to URL**, **File path or URL: `udp://127.0.0.1:47111?pkt_size=1316`**, **Container Format: `mpegts`**, **Video Encoder: `libx264`**, **Video Bitrate: `4000` Kbps**, **Keyframe interval: `30` frames**. If encoder settings are exposed, use `preset=veryfast tune=zerolatency`. Audio may remain disabled; it is not sent to the iPhone camera.
5. Find the iPhone Wi-Fi address in **Settings → Wi-Fi → ⓘ**. In a Mac Terminal run `python3 scripts/obs-relay.py --iphone IPHONE_WIFI_IP` from this repository. Leave it running. Its first run fetches the token over USB SSH.
6. In OBS choose any scene and click **Start Recording**. This button starts the URL output configured above; it does not create a local recording file. On iPhone press **Volume Up + Volume Down**, select **LIVE OBS**, then open Camera. Changing scenes in OBS updates subsequent iPhone frames. Use **Disable Replacement** or **Real Camera** to return to the real feed without a respring.

If both devices are connected by USB, run `bash scripts/obs-usb.sh` instead of step 5. The same OBS settings work; the script forwards the authenticated receiver connection over USB. The existing SSH USB tunnel on port `2222` must be running for the first token fetch.

The menu reports connection, FPS, resolution, received-frame age, approximate relay-to-receiver delay, dropped frames, and the last receiver error. The delay metric excludes OBS capture/encode time and camera display time. The receiver retains one complete last frame across a lost connection; the relay's one-slot queue discards old frames to avoid growing lag. Current transport re-encodes to JPEG on the Mac, so it is more bandwidth intensive than native H.264 decoding on iPhone. Audio is not implemented.

#### Automated frame test

`python3 scripts/test-live-obs.py` encodes a synthetic 720p30 source as H.264/MPEG-TS over UDP, then runs it through the Mac relay and receiver on loopback. It verifies authentication, received frames, and disconnect behavior. To test the installed iPhone receiver without OBS, run `python3 scripts/obs-relay.py --iphone IPHONE_WIFI_IP --test-pattern`; select LIVE OBS and open Camera. The menu should show connected 1280×720 at about 30 FPS. Stop the command with Ctrl-C and confirm the menu reports disconnected while the camera holds the last frame.

### Adjust the camera framing

The floating control panel provides quick controls without reopening the main menu:

- **Move:** shift the replacement image or video up, down, left, or right.
- **Reset position:** return the media to its centered position.
- **Rotate:** rotate the media left or right in 90-degree increments.
- **Zoom:** zoom in or out from 0.1× up to 10×.
- **Video playback:** pause or resume the selected video.

### Tune movement and zoom sensitivity

The Settings section lets you choose how much each control press changes the image. Movement and zoom are configured independently.

**Movement per press:** 0.5%, 1%, 2%, 5%, or 10%.

**Zoom per press:** 0.01×, 0.02×, 0.05×, 0.10×, 0.20×, or 0.50×.

Smaller increments provide finer adjustments; larger increments make repositioning and zooming faster. The selected increments are saved and reused after the menu is closed or the device is restarted.

### Floating controls and touch pass-through

- The floating control can be shown or hidden from the main menu.
- Drag the floating button to place it where it is convenient.
- Tap it to open the compact control panel.
- The panel uses compact icon buttons for movement, rotation, zoom, and video playback.
- Touches outside the visible controls pass through to the app underneath while the menu is closed.
- The floating control starts hidden, so it does not appear until you choose **Show Control**.

### Menu, orientation, and diagnostics

- Press **Volume Up + Volume Down** together to open or close the VCam menu.
- The VCam menu panel follows the device's physical portrait or landscape orientation.
- The overlay is designed not to force the SpringBoard Home Screen to rotate.
- **View Logs** displays runtime information such as camera-service status, media loading, video playback, and whether replacement frames are being rendered.
- **Copy Logs** copies the diagnostic information so it can be shared when troubleshooting.

## Typical workflow

1. Open VCam by pressing **Volume Up + Volume Down** together.
2. Choose **Photo**, **Video File**, **LIVE OBS**, or **Real Camera**.
3. Wait for the import or video optimization process to finish. Importing new media enables Replacement automatically.
4. Confirm that Replacement is enabled and that the selected media is ready.
5. Use **Settings** to choose movement and zoom increments.
6. Select **Show Control** to display the floating button, then drag it to a convenient position.
7. Open the compact control panel to reposition, rotate, zoom, or pause/resume the media while using a compatible camera app.

Only one replacement item is selected at a time. Selecting new media replaces the previously imported item in VCam's media storage.

## Example use cases

- **LARP and role-play:** prepare a character image, scene, or pre-recorded clip to use as the camera visual during a compatible session.
- **Livestream scenes:** repeat a prepared video clip as the camera source while the streaming app's camera capture remains active.
- **Continuous or long-running streams:** use the automatic video loop for a repeating visual source. The loop can reduce the need to restart a clip manually, but it does not guarantee an uninterrupted 24/7 broadcast.
- **Creative demonstrations and testing:** check camera framing, media transforms, and camera-dependent app flows with a consistent visual source.

## Important notes and limitations

- On the tested iPhone 11 with iOS 18.3.2, photo replacement reaches the camera render path. Video replacement is currently unavailable because `AVPlayerItemVideoOutput` does not initialize inside `cameracaptured`; the tweak handles that failure without crashing the daemon.
- Video playback is muted. VCam does not transmit the video's audio; provide audio separately through your streaming or recording setup.
- Automatic looping repeats the selected clip while the camera playback path is active. It does not keep a livestream online by itself.
- iOS, SpringBoard, mediaserverd, the camera app, network conditions, battery state, heat, or memory pressure can interrupt a long-running session. Do not treat VCam as a guarantee of unattended 24/7 operation.
- VCam works by hooking a camera capture path used by the iOS camera/media services. Apps that use a different or restricted capture path may continue showing the real camera or may not be compatible.
- The actual result can vary across devices, iOS releases, jailbreak environments, and target apps. Test the exact app and streaming setup before relying on it for a live session.
- Keep the device powered and monitor temperature and stream status during extended use.

## Build packages

The included GitHub Actions workflow builds two Debian packages:

- `vcam-rootless.deb` for a rootless jailbreak environment.
- `vcam-roothide.deb` for a RootHide environment.

To build them, push the source to the repository's `main` or `master` branch, open a pull request targeting either branch, or run the workflow manually from the GitHub Actions tab. Download the generated workflow artifact and install the package that matches your jailbreak environment.

The project is configured with an iOS 15.0 deployment target and uses the iOS 16.5 SDK in its Theos Makefile. Actual compatibility still depends on the device, jailbreak, iOS release, and camera capture path.
