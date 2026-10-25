# Audio Source GUI — In Godot for Linux

A lightweight Linux desktop controller for the [Audio Source Android app](https://github.com/gdzx/audiosource). It turns the phone's microphone stream into a Linux virtual input source and makes it the default input while active.

## Requirements
-  USB debugging turned on android device
- `adb` (Android Debug Bridge)
- `pactl` and a running PulseAudio-compatible server (PulseAudio or PipeWire-Pulse)
- `bash` and `cat` (normally available on Linux)
- The Audio Source Android app installed on the phone

## Run

1. Extract this archive.
2. Run `./run.sh`, or open `project.godot` in Godot 4 and press **Run**.
3. Connect the phone over USB, enable USB debugging, unlock it, and accept its debugging prompt.
4. Press **Detect**, then **Start microphone**. If only one authorized Android device is connected, it can be selected automatically.
5. The virtual microphone becomes the desktop's default input. Adjust its volume in the app.
6. Press **Stop** to stop recording, remove the ADB forward, unload the virtual source, and restore the previous default input when it has not been changed manually.

The GitHub button opens the original Audio Source project page. This project is the Linux desktop controller; install the Android app separately.

## Notes

- If Android permissions cannot be granted through ADB, grant microphone and notification permissions to Audio Source on the phone, then try again.
