# SPDX-License-Identifier: MIT
extends Node3D

var hands: Array[XRController3D] = []
var held: Array[bool] = [false, false]
var target: MeshInstance3D
var target_material: StandardMaterial3D
var target_velocity := Vector3(0.35, 0.2, 0)
var flash_left := 0.0
var score_label: Label3D
var score := 0
var time_left := 60.0
var round_over := false
var shown_second := -1
var menu_open := false
var menu_held: Array[bool] = [false, false]
var esc_held := false
var pause_label: Label3D

func _ready() -> void:
    var origin := XROrigin3D.new()
    add_child(origin)
    var camera := XRCamera3D.new()
    origin.add_child(camera)
    for tracker in ["left_hand", "right_hand"]:
        var hand := XRController3D.new()
        hand.tracker = tracker
        hand.pose = "aim"
        origin.add_child(hand)
        hands.append(hand)
        var marker := MeshInstance3D.new()
        var box := BoxMesh.new()
        box.size = Vector3(0.035, 0.035, 0.12)
        marker.mesh = box
        hand.add_child(marker)
    var light := DirectionalLight3D.new()
    light.rotation_degrees = Vector3(-45, -25, 0)
    add_child(light)
    var environment := WorldEnvironment.new()
    environment.environment = Environment.new()
    environment.environment.background_mode = Environment.BG_COLOR
    environment.environment.background_color = Color(0.07, 0.09, 0.12)
    environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.environment.ambient_light_color = Color(0.65, 0.7, 0.8)
    add_child(environment)
    var floor_mesh := MeshInstance3D.new()
    var plane := PlaneMesh.new()
    plane.size = Vector2(10, 10)
    floor_mesh.mesh = plane
    add_child(floor_mesh)
    target = MeshInstance3D.new()
    var sphere := SphereMesh.new()
    sphere.radius = 0.2
    sphere.height = 0.4
    target.mesh = sphere
    target_material = StandardMaterial3D.new()
    target_material.albedo_color = Color(0.9, 0.35, 0.2)
    sphere.material = target_material
    target.position = Vector3(0, 1.5, -2.5)
    add_child(target)
    score_label = Label3D.new()
    score_label.position = Vector3(0, 2.1, -2.5)
    _update_label()
    pause_label = Label3D.new()
    pause_label.position = Vector3(0, 1.55, -2.2)
    pause_label.text = "Paused\nMenu: resume\nTrigger: quit to Newt"
    pause_label.visible = false
    add_child(pause_label)
    add_child(score_label)
    var xr := XRServer.find_interface("OpenXR")
    if xr != null and xr.is_initialized():
        DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
        get_viewport().use_xr = true
    else:
        score_label.text = "OpenXR unavailable — check runtime and USB connection"
        push_warning("No initialized OpenXR interface. This is a desktop preview only.")

func _update_label() -> void:
    if round_over:
        score_label.text = "Round over! Final score: %d\nTrigger: new round - Menu: pause / quit" % score
    else:
        score_label.text = "Aim at the sphere and squeeze trigger\nScore: %d  Time: %d\nMenu button: pause menu" % [score, ceili(time_left)]

func _toggle_menu() -> void:
    menu_open = not menu_open
    pause_label.visible = menu_open

func _process(delta: float) -> void:
    # Cooperative quit convention for Newt-hosted games: the menu button
    # opens a pause menu instead of leaving instantly. Quitting still means
    # exiting the process; the Newt manager restores the dashboard.
    for i in range(hands.size()):
        var menu_pressed := hands[i].is_button_pressed("menu_button")
        if menu_pressed and not menu_held[i]:
            _toggle_menu()
        menu_held[i] = menu_pressed
    var esc := Input.is_key_pressed(KEY_ESCAPE)
    if esc and not esc_held:
        _toggle_menu()
    esc_held = esc
    if menu_open:
        for i in range(hands.size()):
            var trigger := hands[i].get_float("trigger") > 0.7
            if trigger and not held[i]:
                get_tree().quit()
                return
            held[i] = trigger
        if Input.is_key_pressed(KEY_Q):
            get_tree().quit()
        return
    if not round_over:
        time_left -= delta
        target.position += target_velocity * delta
        if target.position.x < -1.0 or target.position.x > 1.0:
            target_velocity.x = -target_velocity.x
            target.position.x = clampf(target.position.x, -1.0, 1.0)
        if target.position.y < 0.9 or target.position.y > 1.9:
            target_velocity.y = -target_velocity.y
            target.position.y = clampf(target.position.y, 0.9, 1.9)
        if flash_left > 0.0:
            flash_left -= delta
            if flash_left <= 0.0:
                target_material.albedo_color = Color(0.9, 0.35, 0.2)
        if time_left <= 0.0:
            time_left = 0.0
            round_over = true
        if ceili(time_left) != shown_second:
            shown_second = ceili(time_left)
            _update_label()
    for i in range(hands.size()):
        var pressed := hands[i].get_float("trigger") > 0.7
        if pressed and not held[i] and hands[i].get_has_tracking_data():
            if round_over:
                score = 0
                time_left = 60.0
                round_over = false
                _update_label()
            else:
                var offset := target.global_position - hands[i].global_position
                var direction := -hands[i].global_basis.z.normalized()
                var along := offset.dot(direction)
                if along > 0.0 and (offset - direction * along).length() <= 0.2:
                    score += 1
                    hands[i].trigger_haptic_pulse("haptic", 0.0, 0.7, 0.15, 0.0)
                    target_material.albedo_color = Color(1.0, 0.9, 0.3)
                    flash_left = 0.15
                    target.position = Vector3(randf_range(-0.8, 0.8), randf_range(1.1, 1.8), -2.5)
                    target_velocity = Vector3(randf_range(0.25, 0.55) * (1.0 if randf() > 0.5 else -1.0),
                        randf_range(0.15, 0.4) * (1.0 if randf() > 0.5 else -1.0), 0)
                    _update_label()
        held[i] = pressed
