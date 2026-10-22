# SPDX-License-Identifier: MIT
class_name PlayerRig
extends XROrigin3D

## The VR player: camera, two tracked hands with rays, smooth + teleport
## locomotion, snap turning, proximity grabbing with throw velocity, 3D UI
## button presses, and a wrist HUD. World reactions (scoring, buttons) are
## reported through signals so main.gd owns game state.

signal ui_activated(action: String)
signal shot_fired(origin: Vector3, direction: Vector3, hand_index: int)
signal grabbed(body: RigidBody3D)
signal released(body: RigidBody3D)
signal menu_pressed
signal teleported

const Factory := preload("res://scripts/factory.gd")

var camera: XRCamera3D
var hands: Array[XRController3D] = []
var hand_meshes: Array[Node3D] = []
var rays: Array[MeshInstance3D] = []
var ray_hits: Array = [{}, {}]
var locomotion_mode := 0  # 0 = smooth + snap turn, 1 = teleport + snap turn
var interaction_enabled := true

var _trigger_held: Array[bool] = [false, false]
var _grip_held: Array[bool] = [false, false]
var _menu_held: Array[bool] = [false, false]
var _snap_ready := true
var _held_bodies: Array = [null, null]
var _held_offsets: Array[Transform3D] = [Transform3D(), Transform3D()]
var _hand_history: Array = [[], []]
var _teleport_aiming := false
var _teleport_target := Vector3.ZERO
var _teleport_valid := false
var _teleport_arc: MeshInstance3D
var _teleport_marker: MeshInstance3D
var _hud: Label3D
var _hud_timer := 0.0

func _ready() -> void:
	camera = XRCamera3D.new()
	add_child(camera)
	var hand_colors := [Color(0.25, 0.55, 1.0), Color(1.0, 0.55, 0.25)]
	for i in range(2):
		var hand := XRController3D.new()
		hand.tracker = "left_hand" if i == 0 else "right_hand"
		hand.pose = "aim"
		add_child(hand)
		hands.append(hand)
		var mitt := Node3D.new()
		hand.add_child(mitt)
		hand_meshes.append(mitt)
		var palm := MeshInstance3D.new()
		var palm_mesh := SphereMesh.new()
		palm_mesh.radius = 0.035
		palm_mesh.height = 0.07
		palm_mesh.material = Factory.mat(hand_colors[i], 0.5)
		palm.mesh = palm_mesh
		palm.scale = Vector3(1.0, 0.55, 1.5)
		mitt.add_child(palm)
		var tip := MeshInstance3D.new()
		var tip_mesh := SphereMesh.new()
		tip_mesh.radius = 0.016
		tip_mesh.height = 0.032
		tip_mesh.material = Factory.mat(hand_colors[i].lightened(0.35), 0.4)
		tip.mesh = tip_mesh
		tip.position = Vector3(0, 0.012, -0.075)
		mitt.add_child(tip)
		var ray := MeshInstance3D.new()
		ray.mesh = ImmediateMesh.new()
		var ray_material := StandardMaterial3D.new()
		ray_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ray_material.albedo_color = hand_colors[i]
		ray.material_override = ray_material
		ray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		hand.add_child(ray)
		rays.append(ray)
	_hud = Label3D.new()
	_hud.font_size = 36
	_hud.pixel_size = 0.0016
	_hud.modulate = Color(0.85, 0.95, 1.0)
	_hud.outline_size = 6
	_hud.position = Vector3(0.02, 0.07, 0.03)
	_hud.rotation_degrees = Vector3(-55, 0, 0)
	hands[0].add_child(_hud)
	_teleport_arc = MeshInstance3D.new()
	_teleport_arc.mesh = ImmediateMesh.new()
	var arc_material := StandardMaterial3D.new()
	arc_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arc_material.albedo_color = Color(0.4, 1.0, 0.7)
	_teleport_arc.material_override = arc_material
	_teleport_arc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_teleport_arc.top_level = true
	_teleport_arc.visible = false
	add_child(_teleport_arc)
	_teleport_marker = MeshInstance3D.new()
	var ring := TorusMesh.new()
	ring.inner_radius = 0.22
	ring.outer_radius = 0.28
	ring.material = Factory.mat(Color(0.4, 1.0, 0.7), 0.4, 0.0, Color(0.4, 1.0, 0.7), 0.8)
	_teleport_marker.mesh = ring
	_teleport_marker.rotation_degrees.x = 90
	_teleport_marker.top_level = true
	_teleport_marker.visible = false
	add_child(_teleport_marker)

func set_hud_text(text: String) -> void:
	if _hud != null:
		_hud.text = text

func _physics_process(_delta: float) -> void:
	_update_rays()

func _process(delta: float) -> void:
	_update_menu_buttons()
	_update_hands(delta)
	if interaction_enabled:
		_update_locomotion(delta)
		_update_grabs(delta)
	# Triggers always run so pause-panel buttons stay clickable while the
	# world is paused; main.gd decides what a shot means in that state.
	_update_triggers()
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.25
		if _hud != null and _hud.text == "":
			_hud.text = "%d FPS" % Engine.get_frames_per_second()

func _update_menu_buttons() -> void:
	for i in range(hands.size()):
		var pressed := hands[i].is_button_pressed("menu_button")
		if pressed and not _menu_held[i]:
			menu_pressed.emit()
		_menu_held[i] = pressed

func _update_hands(_delta: float) -> void:
	for i in range(hands.size()):
		var tracked := hands[i].get_has_tracking_data()
		hand_meshes[i].visible = tracked
		rays[i].visible = tracked
		if tracked:
			var squeeze := clampf(hands[i].get_float("grip"), 0.0, 1.0)
			hand_meshes[i].scale = Vector3.ONE * lerpf(1.0, 0.72, squeeze)

func _update_rays() -> void:
	var space := get_world_3d().direct_space_state
	for i in range(hands.size()):
		ray_hits[i] = {}
		if not hands[i].get_has_tracking_data():
			continue
		var from := hands[i].global_position
		var direction := -hands[i].global_basis.z.normalized()
		var query := PhysicsRayQueryParameters3D.create(from, from + direction * 30.0,
			Factory.LAYER_WORLD | Factory.LAYER_UI | Factory.LAYER_PROP)
		var hit := space.intersect_ray(query)
		ray_hits[i] = hit
		var end: Vector3 = hit.get("position", from + direction * 8.0)
		var mesh := rays[i].mesh as ImmediateMesh
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		mesh.surface_add_vertex(Vector3(0, 0, -0.06))
		mesh.surface_add_vertex(hands[i].to_local(end))
		mesh.surface_end()

func _update_triggers() -> void:
	for i in range(hands.size()):
		var pressed := hands[i].get_float("trigger") > 0.7
		if pressed and not _trigger_held[i] and hands[i].get_has_tracking_data():
			var hit: Dictionary = ray_hits[i]
			var collider: Object = hit.get("collider")
			if collider is StaticBody3D and collider.has_meta("ui_action"):
				_press_button(collider)
			else:
				shot_fired.emit(hands[i].global_position,
					-hands[i].global_basis.z.normalized(), i)
				hands[i].trigger_haptic_pulse("haptic", 0.0, 0.35, 0.05, 0.0)
		_trigger_held[i] = pressed

func _press_button(body: StaticBody3D) -> void:
	var tween := create_tween()
	var start_z := body.position.z
	tween.tween_property(body, "position:z", start_z - 0.015, 0.06)
	tween.tween_property(body, "position:z", start_z, 0.10)
	ui_activated.emit(String(body.get_meta("ui_action")))

func _update_grabs(delta: float) -> void:
	for i in range(hands.size()):
		var hand := hands[i]
		_hand_history[i].push_front(hand.global_position)
		if _hand_history[i].size() > 6:
			_hand_history[i].pop_back()
		var gripping := hand.get_float("grip") > 0.7
		if gripping and not _grip_held[i] and hand.get_has_tracking_data() and _held_bodies[i] == null:
			var best: RigidBody3D = null
			var best_distance := 0.38
			for node in get_tree().get_nodes_in_group("grabbable"):
				var candidate := node as RigidBody3D
				if candidate == null or _held_bodies.has(candidate):
					continue
				var distance := hand.global_position.distance_to(candidate.global_position)
				if distance < best_distance:
					best = candidate
					best_distance = distance
			if best != null:
				_held_bodies[i] = best
				_held_offsets[i] = hand.global_transform.affine_inverse() * best.global_transform
				best.freeze = true
				hand.trigger_haptic_pulse("haptic", 0.0, 0.5, 0.08, 0.0)
				grabbed.emit(best)
		if not gripping and _grip_held[i] and _held_bodies[i] != null:
			var body: RigidBody3D = _held_bodies[i]
			_held_bodies[i] = null
			body.freeze = false
			body.linear_velocity = _hand_velocity(i, delta)
			body.angular_velocity = Vector3.ZERO
			body.sleeping = false
			released.emit(body)
		_grip_held[i] = gripping
		if _held_bodies[i] != null:
			(_held_bodies[i] as RigidBody3D).global_transform = hand.global_transform * _held_offsets[i]

func _hand_velocity(index: int, delta: float) -> Vector3:
	var history: Array = _hand_history[index]
	if history.size() < 2 or delta <= 0.0:
		return Vector3.ZERO
	var newest: Vector3 = history[0]
	var oldest: Vector3 = history[history.size() - 1]
	var span := delta * float(history.size() - 1)
	if span <= 0.0:
		return Vector3.ZERO
	return ((newest - oldest) / span).limit_length(12.0)

func _update_locomotion(delta: float) -> void:
	# Snap turn on the right stick, in both modes.
	var turn_axis := hands[1].get_vector2("primary")
	if absf(turn_axis.x) > 0.75 and _snap_ready:
		_snap_turn(signf(turn_axis.x) * -45.0)
		_snap_ready = false
	elif absf(turn_axis.x) < 0.3:
		_snap_ready = true
	if locomotion_mode == 0:
		_teleport_arc.visible = false
		_teleport_marker.visible = false
		var move_axis := hands[0].get_vector2("primary")
		if move_axis.length() > 0.15 and camera != null:
			var forward := -camera.global_basis.z
			forward.y = 0
			forward = forward.normalized()
			var right := camera.global_basis.x
			right.y = 0
			right = right.normalized()
			var wish := (right * move_axis.x - forward * move_axis.y).limit_length(1.0)
			global_position = (global_position + wish * 2.2 * delta).clamp(
				Vector3(-9, 0, -11), Vector3(9, 0, 6))
	else:
		_update_teleport()

func _snap_turn(degrees: float) -> void:
	if camera == null:
		return
	var angle := deg_to_rad(degrees)
	var pivot := camera.global_position
	pivot.y = 0
	global_position = pivot + Basis(Vector3.UP, angle) * (global_position - pivot)
	rotate_y(angle)

func _update_teleport() -> void:
	var stick := hands[1].get_vector2("primary")
	var aiming := stick.y < -0.6 and hands[1].get_has_tracking_data()
	if aiming:
		var from := hands[1].global_position
		var velocity := -hands[1].global_basis.z.normalized() * 6.0 + Vector3.UP * 1.5
		var points: Array[Vector3] = []
		_teleport_valid = false
		for step in range(32):
			var t := float(step) * 0.08
			var point := from + velocity * t + Vector3(0, -4.9, 0) * t * t
			points.append(point)
			if point.y <= 0.02 and step > 0:
				_teleport_target = Vector3(point.x, 0, point.z)
				_teleport_valid = absf(point.x) <= 9.0 and point.z >= -11.0 and point.z <= 6.0
				break
		var mesh := _teleport_arc.mesh as ImmediateMesh
		mesh.clear_surfaces()
		mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for point in points:
			mesh.surface_add_vertex(point)
		mesh.surface_end()
		_teleport_arc.visible = true
		_teleport_marker.visible = _teleport_valid
		if _teleport_valid:
			_teleport_marker.global_position = _teleport_target + Vector3(0, 0.03, 0)
		_teleport_aiming = true
	elif _teleport_aiming:
		_teleport_aiming = false
		_teleport_arc.visible = false
		_teleport_marker.visible = false
		if _teleport_valid and camera != null:
			var offset := camera.global_position - global_position
			offset.y = 0
			global_position = _teleport_target - offset
			hands[1].trigger_haptic_pulse("haptic", 0.0, 0.5, 0.1, 0.0)
			teleported.emit()
