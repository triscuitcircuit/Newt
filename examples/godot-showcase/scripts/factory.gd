# SPDX-License-Identifier: MIT
class_name ShowcaseFactory
extends RefCounted

## Static builders for the showcase's code-built world: materials, static
## geometry, grabbable physics props, pressable 3D buttons, and text signs.
## Everything is primitive meshes so the demo has zero imported assets.

const LAYER_WORLD := 1
const LAYER_UI := 2
const LAYER_PROP := 4

static func mat(color: Color, roughness: float = 0.8, metallic: float = 0.0,
		emission: Color = Color.BLACK, emission_energy: float = 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = emission
		material.emission_energy_multiplier = emission_energy
	return material

static func box(parent: Node, pos: Vector3, size: Vector3, material: Material,
		rotation_y_degrees: float = 0.0, collide: bool = true) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = material
	mesh_instance.mesh = mesh
	mesh_instance.position = pos
	mesh_instance.rotation_degrees.y = rotation_y_degrees
	parent.add_child(mesh_instance)
	if collide:
		var body := StaticBody3D.new()
		body.collision_layer = LAYER_WORLD
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		body.add_child(shape)
		mesh_instance.add_child(body)
	return mesh_instance

static func cylinder(parent: Node, pos: Vector3, top_radius: float, bottom_radius: float,
		height: float, material: Material, collide: bool = true) -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.material = material
	mesh_instance.mesh = mesh
	mesh_instance.position = pos
	parent.add_child(mesh_instance)
	if collide:
		var body := StaticBody3D.new()
		body.collision_layer = LAYER_WORLD
		var shape := CollisionShape3D.new()
		var cyl_shape := CylinderShape3D.new()
		cyl_shape.radius = maxf(top_radius, bottom_radius)
		cyl_shape.height = height
		shape.shape = cyl_shape
		body.add_child(shape)
		mesh_instance.add_child(body)
	return mesh_instance

static func grabbable_box(parent: Node, pos: Vector3, size: float, material: Material) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.collision_layer = LAYER_PROP
	body.collision_mask = LAYER_WORLD | LAYER_PROP
	body.position = pos
	body.add_to_group("grabbable")
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * size
	mesh.material = material
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3.ONE * size
	shape.shape = box_shape
	body.add_child(shape)
	parent.add_child(body)
	return body

static func grabbable_ball(parent: Node, pos: Vector3, radius: float, material: Material) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.collision_layer = LAYER_PROP
	body.collision_mask = LAYER_WORLD | LAYER_PROP
	body.position = pos
	body.add_to_group("grabbable")
	var physics := PhysicsMaterial.new()
	physics.bounce = 0.55
	body.physics_material_override = physics
	var mesh_instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = material
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)
	var shape := CollisionShape3D.new()
	var sphere_shape := SphereShape3D.new()
	sphere_shape.radius = radius
	shape.shape = sphere_shape
	body.add_child(shape)
	parent.add_child(body)
	return body

## A pressable panel button. The player rig raycasts StaticBody3D colliders on
## LAYER_UI and reads the "ui_action" metadata from the collider's owner body.
static func button(parent: Node, pos: Vector3, rotation_y_degrees: float, label: String,
		action: String, color: Color) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = LAYER_UI
	body.collision_mask = 0
	body.position = pos
	body.rotation_degrees.y = rotation_y_degrees
	body.set_meta("ui_action", action)
	body.add_to_group("ui_button")
	var size := Vector3(0.34, 0.13, 0.04)
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mat(color, 0.45, 0.1, color, 0.35)
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)
	var shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	body.add_child(shape)
	var text := Label3D.new()
	text.text = label
	text.font_size = 48
	text.pixel_size = 0.0022
	text.modulate = Color.WHITE
	text.outline_size = 8
	text.position = Vector3(0, 0, 0.025)
	text.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	body.add_child(text)
	body.set_meta("label_node", text)
	parent.add_child(body)
	return body

static func sign(parent: Node, pos: Vector3, rotation_y_degrees: float, title: String, body: String) -> Label3D:
	var backing := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.5, 0.95, 0.05)
	mesh.material = mat(Color(0.10, 0.12, 0.16), 0.6, 0.2)
	backing.mesh = mesh
	backing.position = pos
	backing.rotation_degrees.y = rotation_y_degrees
	parent.add_child(backing)
	var text := Label3D.new()
	text.text = title + "\n" + body
	text.font_size = 44
	text.pixel_size = 0.0028
	text.modulate = Color(0.92, 0.96, 1.0)
	text.outline_size = 6
	text.width = 480.0
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.position = Vector3(0, 0, 0.035)
	backing.add_child(text)
	return text
