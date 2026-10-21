# SPDX-License-Identifier: MIT
extends SceneTree

## Headless smoke test for the showcase:
##   godot --headless --path . -s tests/showcase_smoke.gd
## Instantiates the real scene in desktop-preview mode and drives the same
## handlers controller input would: every pedestal action, a scoring shot,
## and the pause panel. Exits 0 only if all checks pass. Validates scripts
## and scene assembly only — never OpenXR, rendering, or USB.

var _failures := 0

func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: ", label)
	else:
		_failures += 1
		push_error("FAIL: " + label)

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var packed := load("res://main.tscn") as PackedScene
	_check(packed != null, "main scene loads")
	var main = packed.instantiate()
	root.add_child(main)
	for i in range(12):
		await physics_frame
	_check(get_nodes_in_group("grabbable").size() >= 10, "physics yard props exist")
	_check(get_nodes_in_group("ui_button").size() >= 6, "pedestal + pause buttons exist")
	_check(main.rig != null and main.rig.hands.size() == 2, "player rig built with two hands")

	var props_before := get_nodes_in_group("grabbable").size()
	main._on_ui_activated("spawn_ball")
	_check(get_nodes_in_group("grabbable").size() == props_before + 1, "spawn_ball adds a grabbable")

	main._on_ui_activated("toggle_locomotion")
	_check(main.rig.locomotion_mode == 1, "locomotion toggles to teleport")
	main._on_ui_activated("toggle_locomotion")
	_check(main.rig.locomotion_mode == 0, "locomotion toggles back to smooth")

	main._on_ui_activated("toggle_dusk")
	_check(main._dusk, "dusk preset engages")
	main._on_ui_activated("toggle_dusk")
	_check(not main._dusk, "day preset restores")

	var a_prop := get_nodes_in_group("grabbable")[0] as RigidBody3D
	a_prop.global_position += Vector3(0, 1.5, 0)
	main._on_ui_activated("reset_physics")
	for i in range(3):
		await physics_frame
	_check(a_prop.global_position.distance_to((main._props_home[a_prop] as Transform3D).origin) < 0.6,
		"reset_physics returns props home")

	# Aim a synthetic shot exactly at the first target's current position.
	var target_node: MeshInstance3D = main._targets[0]["node"]
	var origin := target_node.global_position + Vector3(0, 0, 3.0)
	var direction := (target_node.global_position - origin).normalized()
	var score_before: int = main._score
	main._on_shot_fired(origin, direction, 0)
	_check(main._score == score_before + 1, "aimed shot scores")

	main._toggle_pause()
	_check(main._menu_open and main._pause_panel.visible, "pause panel opens")
	_check(not main.rig.interaction_enabled, "locomotion/grab disabled while paused")
	main._on_ui_activated("pause_resume")
	_check(not main._menu_open, "pause panel closes on resume")

	print("showcase_smoke: %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
