
# Table of Contents

1.  [What's in the scene](#org9ff8095)
2.  [Controls](#org0cabf30)
3.  [Run it](#orgd1a3db2)
4.  [Validate without a headset](#org54d36a6)
5.  [Layout](#org1844283)

A native Godot 4 OpenXR demo for Mac: one small island, three stations,
built entirely in code from primitives — no imported assets. It exists to
show what Mac-native VR through OpenXR (Godot's Vulkan renderer on a local
runtime such as the Monado Quest Link driver) can do today, and to exercise
the Newt session-manager handoff end to end.

For the minimal starter project, see [`../godot`](../godot). This is the
bigger sibling.


<a id="org9ff8095"></a>

# What's in the scene

-   **The Atrium** — emissive crystal spire, counter-rotating metallic rings,
    a GPU particle fountain, procedural sky, and a day/dusk lighting toggle
    with animated transitions.
-   **Physics Yard** — a crate pyramid, bouncy balls, and a seesaw plank.
    Grab any prop with the grip, carry it, throw it with real hand velocity.
-   **Target Range** — five floating targets on animated paths that speed up
    as you score, ray shooting with haptic pulses and generated sound effects.
-   **Control pedestal** — physical 3D buttons: Spawn Ball, Reset Physics,
    Dusk/Day, and Teleport on/off.
-   **Everywhere** — 140-instance MultiMesh scatter in one draw call, dynamic
    shadows, ACES tonemapping with glow, fog, and a wrist HUD with live
    score/shots/FPS.


<a id="org0cabf30"></a>

# Controls

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">Input</th>
<th scope="col" class="org-left">Action</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left">Left thumbstick</td>
<td class="org-left">Smooth move (or nothing in teleport mode)</td>
</tr>

<tr>
<td class="org-left">Right thumbstick ↔</td>
<td class="org-left">Snap turn 45°</td>
</tr>

<tr>
<td class="org-left">Right thumbstick ↑ (teleport mode)</td>
<td class="org-left">Aim teleport arc, release to jump</td>
</tr>

<tr>
<td class="org-left">Trigger</td>
<td class="org-left">Shoot targets / press 3D buttons</td>
</tr>

<tr>
<td class="org-left">Grip (near a prop)</td>
<td class="org-left">Grab · release to throw</td>
</tr>

<tr>
<td class="org-left">Menu button</td>
<td class="org-left">Pause panel: Resume, or Quit to Newt</td>
</tr>
</tbody>
</table>

Quitting follows the Newt cooperative convention: the game exits its
process and the session manager restores the Newt dashboard.

Desktop preview (no headset): the camera slowly orbits the island.
`Esc` opens the pause panel, `Q` quits from it.


<a id="orgd1a3db2"></a>

# Run it

Requirements match the [minimal example](../godot): Godot 4.4 with OpenXR +
Vulkan on macOS, a compatible separately-supplied OpenXR runtime, matching
architectures, and an awake headset with no other app owning the session.

**Editor Play (recommended):** open this folder in Godot, configure Newt
once via **Project → Tools → Configure Newt…**, press Play. The bundled
Newt Play Bridge starts/reuses the session manager, reserves the headset,
and restores the dashboard on Stop.

**Session manager CLI:**

    # After building Newt (or use the installed `newt` command):
    ../../build/newtd run --project "$PWD"

**Direct launcher (no Newt):**

    python3 launch.py --runtime /absolute/path/to/runtime.json --godot /path/to/Godot


<a id="org54d36a6"></a>

# Validate without a headset

    godot --headless --path . --import
    godot --headless --path . -s tests/showcase_smoke.gd

The smoke test instantiates the real scene in desktop-preview mode and
drives every pedestal action, a scoring shot, and the pause flow. It
validates scripts and scene assembly only. OpenXR initialization,
controller bindings, frame timing, USB transport, and comfort still need a
hardware run — that part is honestly unverified until someone puts the
headset on.


<a id="org1844283"></a>

# Layout

<table border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides">


<colgroup>
<col  class="org-left" />

<col  class="org-left" />
</colgroup>
<thead>
<tr>
<th scope="col" class="org-left">File</th>
<th scope="col" class="org-left">Role</th>
</tr>
</thead>
<tbody>
<tr>
<td class="org-left"><code>main.gd</code></td>
<td class="org-left">World building, stations, scoring, pause, day/dusk</td>
</tr>

<tr>
<td class="org-left"><code>scripts/player_rig.gd</code></td>
<td class="org-left">Hands, rays, locomotion, teleport, grabbing, HUD</td>
</tr>

<tr>
<td class="org-left"><code>scripts/factory.gd</code></td>
<td class="org-left">Materials, props, 3D buttons, signs</td>
</tr>

<tr>
<td class="org-left"><code>scripts/sound_bank.gd</code></td>
<td class="org-left">Procedural WAV sound effects (no assets)</td>
</tr>

<tr>
<td class="org-left"><code>tests/showcase_smoke.gd</code></td>
<td class="org-left">Headless interaction smoke test</td>
</tr>

<tr>
<td class="org-left"><code>addons/newt_bridge/</code></td>
<td class="org-left">Newt Play Bridge (installed, do not edit here)</td>
</tr>
</tbody>
</table>

Godot owns its OpenXR session here — `Newt_Run()` is never called inside
the game. Newt's role is the dashboard/launcher around it and the
one-owner handoff, exactly as in the minimal example.

