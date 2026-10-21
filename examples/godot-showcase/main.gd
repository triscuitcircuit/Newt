# SPDX-License-Identifier: MIT
extends Node3D

## Newt Mac VR Showcase — a native Godot OpenXR demo for Mac.
##
## One small island, three stations: an atrium centerpiece (particles,
## animated rings, day/dusk lighting), a physics yard (grab, throw, stack),
## and a target range (ray shooting with haptics and sound). Locomotion is
## smooth-stick plus snap turn, or teleport — switchable at the pedestal.
## Exiting follows the Newt cooperative convention: Menu opens a pause
## panel, Quit exits the process, and the session manager restores Newt.
##
## Everything is built in code from primitives; there are no imported assets.
## Without an OpenXR runtime the scene still runs as an orbiting desktop
## preview so scripts can be validated headlessly.

const Factory := preload("res://scripts/factory.gd")
const PlayerRigScene := preload("res://scripts/player_rig.gd")
const SoundBankScene := preload("res://scripts/sound_bank.gd")

var rig: PlayerRig
var sounds: SoundBank
var xr_active := false

var _sun: DirectionalLight3D
var _sky_material: ProceduralSkyMaterial
var _environment: Environment
var _dusk := false
var _spinners: Array[Dictionary] = []
var _water_material: StandardMaterial3D
var _targets: Array[Dictionary] = []
var _props_home: Dictionary = {}
var _score := 0
var _shots := 0
var _ball_colors: Array[Color] = [
	Color(0.95, 0.45, 0.25), Color(0.30, 0.70, 1.00), Color(0.45, 0.95, 0.55),
	Color(0.98, 0.80, 0.30), Color(0.80, 0.50, 0.98),
]
var _ball_index := 0
var _locomotion_button: StaticBody3D
var _pause_panel: Node3D
var _menu_open := false
var _esc_held := false
var _desktop_pivot: Node3D
var _hud_timer := 0.0
var _elapsed := 0.0

func _ready() -> void:
	randomize()
	sounds = SoundBankScene.new()
	add_child(sounds)
	_build_environment()
	_build_island()
	_build_atrium()
	_build_physics_yard()
	_build_target_range()
	_build_pedestal()
	_build_pause_panel()
	rig = PlayerRigScene.new()
	rig.position = Vector3(0, 0, 3.5)
	add_child(rig)
	rig.ui_activated.connect(_on_ui_activated)
	rig.shot_fired.connect(_on_shot_fired)
	rig.grabbed.connect(func(body: RigidBody3D) -> void: sounds.play("grab", body.global_position))
	rig.released.connect(func(body: RigidBody3D) -> void: sounds.play("release", body.global_position))
	rig.teleported.connect(func() -> void: sounds.play("teleport", rig.global_position + Vector3(0, 1.4, 0)))
	rig.menu_pressed.connect(_toggle_pause)
	var xr := XRServer.find_interface("OpenXR")
	if xr != null and xr.is_initialized():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		get_viewport().use_xr = true
		xr_active = true
	else:
		_setup_desktop_preview()
		push_warning("No initialized OpenXR interface. Desktop preview only.")

func _build_environment() -> void:
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-48, -28, 0)
	_sun.shadow_enabled = true
	_sun.light_energy = 1.15
	add_child(_sun)
	_sky_material = ProceduralSkyMaterial.new()
	_sky_material.sky_top_color = Color(0.22, 0.46, 0.85)
	_sky_material.sky_horizon_color = Color(0.72, 0.82, 0.95)
	_sky_material.ground_bottom_color = Color(0.10, 0.16, 0.24)
	_sky_material.ground_horizon_color = Color(0.55, 0.65, 0.78)
	_sky_material.sun_angle_max = 30.0
	var sky := Sky.new()
	sky.sky_material = _sky_material
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_SKY
	_environment.sky = sky
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_BG
	_environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	_environment.glow_enabled = true
	_environment.fog_enabled = true
	_environment.fog_light_color = Color(0.72, 0.82, 0.95)
	_environment.fog_density = 0.012
	var world_env := WorldEnvironment.new()
	world_env.environment = _environment
	add_child(world_env)
	for spec in [[Vector3(-5, 2.2, -1), Color(0.45, 0.75, 1.0)],
			[Vector3(5, 2.2, -1), Color(1.0, 0.65, 0.40)],
			[Vector3(0, 2.6, -8.5), Color(0.65, 1.0, 0.75)]]:
		var omni := OmniLight3D.new()
		omni.position = spec[0]
		omni.light_color = spec[1]
		omni.light_energy = 0.7
		omni.omni_range = 7.0
		add_child(omni)

func _build_island() -> void:
	_water_material = Factory.mat(Color(0.10, 0.34, 0.55, 0.88), 0.15, 0.1)
	_water_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var water := MeshInstance3D.new()
	var water_mesh := PlaneMesh.new()
	water_mesh.size = Vector2(90, 90)
	water_mesh.material = _water_material
	water.mesh = water_mesh
	water.position = Vector3(0, -0.35, -2)
	add_child(water)
	Factory.box(self, Vector3(0, -0.5, -2), Vector3(21, 1.0, 19), Factory.mat(Color(0.24, 0.42, 0.26), 0.95))
	Factory.box(self, Vector3(0, 0.02, -2), Vector3(8, 0.04, 8), Factory.mat(Color(0.55, 0.56, 0.58), 0.7))
	Factory.box(self, Vector3(-5, 0.02, -1), Vector3(5.5, 0.04, 5.5), Factory.mat(Color(0.62, 0.55, 0.45), 0.85))
	Factory.box(self, Vector3(0, 0.02, -7.6), Vector3(7, 0.04, 2.6), Factory.mat(Color(0.50, 0.52, 0.56), 0.7))
	# A ring of instanced rocks/trees: one draw call for the whole scatter.
	var scatter := MultiMeshInstance3D.new()
	var rock_mesh := BoxMesh.new()
	rock_mesh.size = Vector3(0.35, 0.5, 0.35)
	rock_mesh.material = Factory.mat(Color(0.35, 0.48, 0.34), 0.95)
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = rock_mesh
	multi.instance_count = 140
	for i in range(multi.instance_count):
		var angle := TAU * float(i) / float(multi.instance_count) + randf_range(-0.04, 0.04)
		var radius := randf_range(8.2, 10.2)
		var pos := Vector3(cos(angle) * radius, 0.2, -2.0 + sin(angle) * radius * 0.86)
		var basis := Basis(Vector3.UP, randf() * TAU).scaled(
			Vector3(randf_range(0.7, 1.6), randf_range(0.8, 2.4), randf_range(0.7, 1.6)))
		multi.set_instance_transform(i, Transform3D(basis, pos))
	scatter.multimesh = multi
	add_child(scatter)

func _build_atrium() -> void:
	var crystal := Factory.mat(Color(0.45, 0.85, 1.0), 0.25, 0.1, Color(0.35, 0.75, 1.0), 1.2)
	Factory.cylinder(self, Vector3(0, 1.1, -4.5), 0.05, 0.55, 2.2, crystal)
	Factory.cylinder(self, Vector3(-1.4, 0.7, -4.9), 0.04, 0.35, 1.4, crystal)
	Factory.cylinder(self, Vector3(1.4, 0.85, -4.1), 0.04, 0.42, 1.7, crystal)
	Factory.cylinder(self, Vector3(0, 0.25, -4.5), 1.3, 1.5, 0.5, Factory.mat(Color(0.32, 0.34, 0.38), 0.6, 0.3))
	for spec in [[2.1, 20.0, Vector3(1, 0.3, 0)], [2.7, -13.0, Vector3(0.2, 0, 1)]]:
		var ring_node := MeshInstance3D.new()
		var ring_mesh := TorusMesh.new()
		ring_mesh.inner_radius = spec[0] - 0.07
		ring_mesh.outer_radius = spec[0] + 0.07
		ring_mesh.material = Factory.mat(Color(0.85, 0.70, 0.35), 0.3, 0.85, Color(0.9, 0.7, 0.3), 0.4)
		ring_node.mesh = ring_mesh
		ring_node.position = Vector3(0, 2.4, -4.5)
		add_child(ring_node)
		_spinners.append({"node": ring_node, "speed": spec[1], "axis": spec[2]})
	var fountain := GPUParticles3D.new()
	fountain.amount = 260
	fountain.lifetime = 1.7
	fountain.position = Vector3(0, 2.35, -4.5)
	var particle_mat := ParticleProcessMaterial.new()
	particle_mat.direction = Vector3(0, 1, 0)
	particle_mat.spread = 14.0
	particle_mat.initial_velocity_min = 2.2
	particle_mat.initial_velocity_max = 3.4
	particle_mat.gravity = Vector3(0, -5.5, 0)
	particle_mat.scale_min = 0.6
	particle_mat.scale_max = 1.4
	fountain.process_material = particle_mat
	var droplet := SphereMesh.new()
	droplet.radius = 0.018
	droplet.height = 0.036
	droplet.material = Factory.mat(Color(0.55, 0.85, 1.0), 0.2, 0.0, Color(0.4, 0.7, 1.0), 0.9)
	fountain.draw_pass_1 = droplet
	add_child(fountain)
	Factory.sign(self, Vector3(-2.6, 1.25, -2.2), 24.0, "NEWT MAC VR SHOWCASE",
		"Native Godot OpenXR on Mac. Walk (left stick), snap-turn (right stick), "
		+ "grab with grip, shoot and press with trigger. Menu pauses; Quit returns to Newt.")
	Factory.sign(self, Vector3(2.7, 1.25, -3.4), -30.0, "THE ATRIUM",
		"Particles, emissive crystals, and animated rings. Use the pedestal behind "
		+ "spawn to toggle dusk lighting and locomotion modes.")

func _build_physics_yard() -> void:
	Factory.sign(self, Vector3(-5, 1.25, 1.6), 0.0, "PHYSICS YARD",
		"Squeeze grip near a crate or ball to pick it up. Throw it, stack it, "
		+ "knock the pyramid down. Reset lives on the pedestal.")
	var crate_mat := Factory.mat(Color(0.72, 0.50, 0.28), 0.85)
	var crate_size := 0.34
	for row in range(3):
		for col in range(3 - row):
			var pos := Vector3(-5.6 + col * (crate_size + 0.02) + row * crate_size * 0.5,
				0.19 + row * (crate_size + 0.01), -2.6)
			_register_prop(Factory.grabbable_box(self, pos, crate_size, crate_mat))
	for i in range(4):
		var ball := Factory.grabbable_ball(self,
			Vector3(-4.2 + i * 0.42, 0.16, -0.6 + (i % 2) * 0.4), 0.14,
			Factory.mat(_ball_colors[i % _ball_colors.size()], 0.45))
		_register_prop(ball)
	# A low seesaw plank on a fulcrum, just for tipping crates off.
	Factory.cylinder(self, Vector3(-6.6, 0.22, -0.4), 0.14, 0.14, 0.44, Factory.mat(Color(0.4, 0.4, 0.44), 0.6, 0.4))
	var plank := Factory.grabbable_box(self, Vector3(-6.6, 0.52, -0.4), 0.3, Factory.mat(Color(0.6, 0.42, 0.25), 0.8))
	plank.scale = Vector3(5.0, 0.22, 1.0)
	_register_prop(plank)

func _register_prop(body: RigidBody3D) -> void:
	_props_home[body] = body.transform

func _build_target_range() -> void:
	Factory.sign(self, Vector3(-2.9, 1.25, -6.9), 18.0, "TARGET RANGE",
		"Aim either controller and squeeze the trigger. Floating targets speed "
		+ "up as your score climbs. Watch your wrist for score and FPS.")
	Factory.box(self, Vector3(0, 1.5, -10.4), Vector3(9, 3.0, 0.3), Factory.mat(Color(0.18, 0.22, 0.30), 0.8))
	for i in range(5):
		var center := Vector3(-2.4 + i * 1.2, 1.4 + (i % 2) * 0.35, -9.2)
		var target := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.21
		sphere.height = 0.42
		var material := Factory.mat(Color(0.95, 0.38, 0.22), 0.4, 0.0, Color(0.95, 0.38, 0.22), 0.5)
		sphere.material = material
		target.mesh = sphere
		target.position = center
		add_child(target)
		var halo := MeshInstance3D.new()
		var halo_mesh := TorusMesh.new()
		halo_mesh.inner_radius = 0.26
		halo_mesh.outer_radius = 0.31
		halo_mesh.material = Factory.mat(Color(1.0, 0.85, 0.4), 0.35, 0.6, Color(1.0, 0.8, 0.35), 0.5)
		halo.mesh = halo_mesh
		target.add_child(halo)
		_spinners.append({"node": halo, "speed": 55.0 + i * 12.0, "axis": Vector3(0, 0, 1)})
		_targets.append({
			"node": target, "material": material, "center": center,
			"phase": randf() * TAU, "speed": randf_range(0.5, 0.9), "flash": 0.0,
		})

func _build_pedestal() -> void:
	var stand := Factory.box(self, Vector3(1.35, 0.5, 2.4), Vector3(0.9, 1.0, 0.25),
		Factory.mat(Color(0.22, 0.24, 0.30), 0.6, 0.3), -28.0)
	stand.rotation_degrees.x = -14
	var panel := Node3D.new()
	panel.position = Vector3(1.35, 1.12, 2.32)
	panel.rotation_degrees = Vector3(-14, -28, 0)
	add_child(panel)
	var entries := [
		["Spawn Ball", "spawn_ball", Color(0.25, 0.55, 0.95)],
		["Reset Physics", "reset_physics", Color(0.30, 0.75, 0.45)],
		["Dusk / Day", "toggle_dusk", Color(0.85, 0.55, 0.30)],
		["Teleport: Off", "toggle_locomotion", Color(0.65, 0.45, 0.90)],
	]
	for i in range(entries.size()):
		var pos := Vector3(-0.19 + (i % 2) * 0.38, 0.09 - (i / 2) * 0.18, 0.03)
		var button := Factory.button(panel, pos, 0.0, entries[i][0], entries[i][1], entries[i][2])
		if entries[i][1] == "toggle_locomotion":
			_locomotion_button = button
	var title := Label3D.new()
	title.text = "SHOWCASE CONTROLS"
	title.font_size = 40
	title.pixel_size = 0.0024
	title.modulate = Color(0.9, 0.95, 1.0)
	title.position = Vector3(0, 0.27, 0.02)
	panel.add_child(title)

func _build_pause_panel() -> void:
	_pause_panel = Node3D.new()
	_pause_panel.visible = false
	_pause_panel.top_level = true
	add_child(_pause_panel)
	var backing := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.62, 0.52, 0.03)
	mesh.material = Factory.mat(Color(0.08, 0.10, 0.14, 0.95), 0.6)
	backing.mesh = mesh
	_pause_panel.add_child(backing)
	var title := Label3D.new()
	title.text = "PAUSED"
	title.font_size = 56
	title.pixel_size = 0.003
	title.position = Vector3(0, 0.17, 0.02)
	_pause_panel.add_child(title)
	Factory.button(_pause_panel, Vector3(0, 0.02, 0.03), 0.0, "Resume", "pause_resume", Color(0.30, 0.70, 0.45))
	Factory.button(_pause_panel, Vector3(0, -0.15, 0.03), 0.0, "Quit to Newt", "pause_quit", Color(0.85, 0.35, 0.30))

func _setup_desktop_preview() -> void:
	_desktop_pivot = Node3D.new()
	_desktop_pivot.position = Vector3(0, 0, -2)
	add_child(_desktop_pivot)
	var preview := Camera3D.new()
	preview.position = Vector3(0, 2.4, 8.5)
	_desktop_pivot.add_child(preview)
	preview.look_at(Vector3(0, 1.1, -2), Vector3.UP)
	preview.current = true

func _process(delta: float) -> void:
	_elapsed += delta
	if not xr_active and _desktop_pivot != null:
		_desktop_pivot.rotation_degrees.y += 5.0 * delta
	var esc := Input.is_key_pressed(KEY_ESCAPE)
	if esc and not _esc_held:
		_toggle_pause()
	_esc_held = esc
	if _menu_open and Input.is_key_pressed(KEY_Q):
		get_tree().quit()
	for spinner in _spinners:
		var node: Node3D = spinner["node"]
		node.rotate((spinner["axis"] as Vector3).normalized(), deg_to_rad(float(spinner["speed"])) * delta)
	if _water_material != null:
		_water_material.uv1_offset += Vector3(0.008, 0.013, 0) * delta
	_update_targets(delta)
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.25
		var mode := "Teleport" if rig.locomotion_mode == 1 else "Smooth"
		rig.set_hud_text("Score %d · Shots %d\n%d FPS · %s" % [_score, _shots, Engine.get_frames_per_second(), mode])

func _update_targets(delta: float) -> void:
	var speed_scale := 1.0 + float(_score) * 0.04
	for target in _targets:
		target["phase"] = float(target["phase"]) + delta * float(target["speed"]) * speed_scale
		var phase := float(target["phase"])
		var center: Vector3 = target["center"]
		var node: MeshInstance3D = target["node"]
		node.position = center + Vector3(sin(phase * 1.3) * 0.55, sin(phase * 2.1) * 0.28, cos(phase * 0.7) * 0.25)
		if float(target["flash"]) > 0.0:
			target["flash"] = float(target["flash"]) - delta
			if float(target["flash"]) <= 0.0:
				(target["material"] as StandardMaterial3D).albedo_color = Color(0.95, 0.38, 0.22)

func _toggle_pause() -> void:
	_menu_open = not _menu_open
	_pause_panel.visible = _menu_open
	rig.interaction_enabled = not _menu_open
	if _menu_open:
		sounds.play("button", rig.global_position + Vector3(0, 1.4, 0))
		if xr_active and rig.camera != null:
			var cam := rig.camera
			_pause_panel.global_position = cam.global_position + -cam.global_basis.z.normalized() * 1.15
			_pause_panel.look_at(cam.global_position, Vector3.UP)
		else:
			_pause_panel.global_position = Vector3(0, 1.5, 0.5)
			_pause_panel.rotation = Vector3.ZERO

func _on_shot_fired(origin: Vector3, direction: Vector3, hand_index: int) -> void:
	if _menu_open:
		return
	_shots += 1
	for target in _targets:
		var node: MeshInstance3D = target["node"]
		var offset := node.global_position - origin
		var along := offset.dot(direction)
		if along <= 0.0:
			continue
		if (offset - direction * along).length() <= 0.24:
			_score += 1
			target["flash"] = 0.18
			(target["material"] as StandardMaterial3D).albedo_color = Color(1.0, 0.9, 0.35)
			target["center"] = Vector3(randf_range(-2.6, 2.6), randf_range(1.0, 2.0), -9.2)
			rig.hands[hand_index].trigger_haptic_pulse("haptic", 0.0, 0.75, 0.15, 0.0)
			sounds.play("hit", node.global_position)
			return

func _on_ui_activated(action: String) -> void:
	sounds.play("button", rig.global_position + Vector3(0, 1.2, 0))
	match action:
		"spawn_ball":
			var ball := Factory.grabbable_ball(self,
				rig.global_position + Vector3(0, 1.6, 0) - rig.global_basis.z.normalized() * 1.2,
				0.14, Factory.mat(_ball_colors[_ball_index % _ball_colors.size()], 0.45))
			_ball_index += 1
			_register_prop(ball)
		"reset_physics":
			for body in _props_home.keys():
				var rigid := body as RigidBody3D
				rigid.freeze = false
				rigid.linear_velocity = Vector3.ZERO
				rigid.angular_velocity = Vector3.ZERO
				rigid.global_transform = _props_home[body]
				rigid.sleeping = false
			sounds.play("thud", Vector3(-5, 0.5, -2))
		"toggle_dusk":
			_dusk = not _dusk
			_apply_lighting_preset()
		"toggle_locomotion":
			rig.locomotion_mode = 1 - rig.locomotion_mode
			var label := _locomotion_button.get_meta("label_node") as Label3D
			label.text = "Teleport: On" if rig.locomotion_mode == 1 else "Teleport: Off"
		"pause_resume":
			_toggle_pause()
		"pause_quit":
			# Cooperative quit: exiting the process hands the headset back;
			# the Newt session manager restores the dashboard.
			get_tree().quit()

func _apply_lighting_preset() -> void:
	var tween := create_tween().set_parallel(true)
	if _dusk:
		tween.tween_property(_sun, "light_energy", 0.45, 1.2)
		tween.tween_property(_sun, "light_color", Color(1.0, 0.62, 0.42), 1.2)
		tween.tween_property(_sun, "rotation_degrees", Vector3(-18, -48, 0), 1.2)
		tween.tween_property(_sky_material, "sky_top_color", Color(0.12, 0.16, 0.38), 1.2)
		tween.tween_property(_sky_material, "sky_horizon_color", Color(0.95, 0.55, 0.38), 1.2)
		tween.tween_property(_environment, "fog_light_color", Color(0.85, 0.52, 0.40), 1.2)
	else:
		tween.tween_property(_sun, "light_energy", 1.15, 1.2)
		tween.tween_property(_sun, "light_color", Color.WHITE, 1.2)
		tween.tween_property(_sun, "rotation_degrees", Vector3(-48, -28, 0), 1.2)
		tween.tween_property(_sky_material, "sky_top_color", Color(0.22, 0.46, 0.85), 1.2)
		tween.tween_property(_sky_material, "sky_horizon_color", Color(0.72, 0.82, 0.95), 1.2)
		tween.tween_property(_environment, "fog_light_color", Color(0.72, 0.82, 0.95), 1.2)
