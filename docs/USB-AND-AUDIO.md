# Optional USB and headset audio

## Build USB support

Install libusb and pkg-config separately (for example `brew install libusb pkg-config`), then configure Newt with `-DNEWT_WITH_USB=ON` in addition to the normal OpenXR/Vulkan build arguments. The default remains OFF.

This adds the shared `Newt::usb` target, `NewtUSB.h`, and `newt-usb-list`. The wrapper source is MIT; it dynamically links against the installed libusb. libusb remains under its own LGPL license and is not copied into this source tree. If you distribute its binary, include its notices and meet its source/relinking requirements; see the [upstream license](https://github.com/libusb/libusb/blob/master/COPYING).

The API supports enumeration, opening an exact enumerated device, claiming an interface, bounded synchronous bulk transfers, and release. It does not reset devices or detach kernel drivers automatically. Calls on a handle must be serialized. Preserve partial transfers on timeout. Re-enumerate after reconnect because bus/address may change. Do not use the listing example's bus/address as a permanent device identity.

For bulk transfers, obtain interface/endpoint values from your device's actual descriptors and protocol. Do not guess endpoints or send test bytes to the headset. Only one owner should claim a headset interface: the OpenXR runtime should own it during a game.

This is a generic transport foundation, not a complete Quest Link backend. A working backend also needs pairing, protocol framing, tracking/controller decoding, video encoding, frame timestamps and poses, pacing, and reconnect. The existing external runtime already supplies much of that functionality, but its compositor includes GPL code; optional builds do not change that code's license. It remains an external runtime rather than MIT Newt source.

## What is needed for USB headset audio

Video files currently play through the Mac system output. USB headset playback requires:

1. Establish the audio-control handshake, sample format/rate/channel count, codec if any, packet framing, timestamps, and queue behavior expected by the headset. Existing protocol schemas contain unknown fields, so these values are not yet verified. A known-good Link USB trace containing audio startup and steady playback would help. It must be captured separately on a setup that already plays audio correctly.
2. Feed decoded media PCM to the transport. For desktop audio, add ScreenCaptureKit audio output and permission handling; for Godot, use an explicit engine audio feed or a system output/capture path. Newt's current AVPlayer-to-Mac path alone does not supply these samples to USB.
3. Resample/channel-map as needed, use a bounded queue, and schedule packets from the correct clock. Keep audio work off render and USB pose threads. Recover from underruns without building latency.
4. Implement volume/mute, stop/flush, and clock reset after pause, sleep and reconnect. Microphone input is a separate feature.
5. Validate on a connected headset: a low-volume test signal, channel identity, lip-sync, long-run drift, load, removal/wake and USB reconnect. Use headphones/Mac audio as the working fallback until this passes.

No arbitrary audio payload has been sent to the headset. The optional libusb wrapper does not by itself make headset audio functional.

## Godot

See [the macOS OpenXR example](../examples/godot/README.md). Godot uses the external runtime directly; Newt can act as a separate dashboard/launcher. A shared in-game dashboard needs a future capture/texture GDExtension, not a second call to Newt_Run.
