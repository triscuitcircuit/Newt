# SPDX-License-Identifier: MIT
class_name SoundBank
extends Node

## Tiny procedural sound effects: sine blips with exponential decay, generated
## as AudioStreamWAV at startup so the demo ships zero audio assets.

const MIX_RATE := 22050

var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer3D] = []
var _next_player := 0

func _ready() -> void:
	_streams["hit"] = _tone([880.0, 1320.0], 0.10, 0.5)
	_streams["grab"] = _tone([330.0], 0.07, 0.4)
	_streams["release"] = _tone([220.0], 0.07, 0.4)
	_streams["button"] = _tone([660.0, 990.0], 0.08, 0.45)
	_streams["teleport"] = _tone([440.0, 660.0, 880.0], 0.12, 0.4)
	_streams["thud"] = _tone([110.0], 0.09, 0.6)
	for i in range(6):
		var player := AudioStreamPlayer3D.new()
		player.max_distance = 30.0
		add_child(player)
		_players.append(player)

func play(sound_name: String, at_position: Vector3) -> void:
	if not _streams.has(sound_name):
		return
	var player := _players[_next_player]
	_next_player = (_next_player + 1) % _players.size()
	player.stream = _streams[sound_name]
	player.global_position = at_position
	player.play()

func _tone(frequencies: Array, seconds: float, volume: float) -> AudioStreamWAV:
	var frames := int(MIX_RATE * seconds)
	var segment := maxi(1, frames / frequencies.size())
	var data := PackedByteArray()
	data.resize(frames * 2)
	for i in range(frames):
		var freq: float = frequencies[mini(i / segment, frequencies.size() - 1)]
		var t := float(i) / MIX_RATE
		var envelope := exp(-6.0 * float(i) / float(frames))
		var sample := int(sin(TAU * freq * t) * envelope * volume * 32767.0)
		data.encode_s16(i * 2, clampi(sample, -32768, 32767))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.data = data
	return stream
