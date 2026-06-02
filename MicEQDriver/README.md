# MicEQ HAL Driver

This is a **virtual CoreAudio device** (AudioServerPlugIn / HAL `.driver`) named **MicEQ**.

It exposes:
- an **output stream** (clients write audio into MicEQ), and
- an **input stream** (other apps read audio from MicEQ).

The driver itself is a simple **loopback** buffer. The MicEQ app is responsible for:
1) capturing a real microphone,
2) applying EQ/DSP, and
3) writing the processed audio to MicEQ’s output stream.

## Build

```sh
mkdir -p build
cmake -S . -B build -DCODESIGN_ID="-"
cmake --build build -j
```

Output:
- `build/MicEQ.driver`

## Install (manual)

```sh
sudo rm -rf "/Library/Audio/Plug-Ins/HAL/MicEQ.driver"
sudo cp -R "build/MicEQ.driver" "/Library/Audio/Plug-Ins/HAL/MicEQ.driver"
sudo xattr -dr com.apple.quarantine "/Library/Audio/Plug-Ins/HAL/MicEQ.driver" || true
sudo killall -9 coreaudiod
```

After restart, **MicEQ** should appear as an audio device (e.g. in Audio MIDI Setup).

