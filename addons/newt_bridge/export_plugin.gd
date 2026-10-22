@tool
extends EditorExportPlugin
# SPDX-License-Identifier: MIT
# After a macOS export, wrap the .app into a self-contained standalone
# bundle via `newtd bundle --runtime ... --bundle-id ...` when the
# project's Newt distribution settings name a runtime manifest. Projects
# without newt/distribution/runtime_manifest see no export-time change.

var owner  # The EditorPlugin (plugin.gd); provides _run_cli/_decode_response.
var export_path := ""

func _get_name() -> String:
    return "NewtStandaloneExport"

func _export_begin(_features: PackedStringArray, _is_debug: bool, path: String, _flags: int) -> void:
    export_path = path

func _export_end() -> void:
    if OS.get_name() != "macOS":
        return
    var runtime := str(ProjectSettings.get_setting("newt/distribution/runtime_manifest", "")).strip_edges()
    if runtime.is_empty():
        return
    if not export_path.ends_with(".app"):
        push_error("Newt standalone export needs a macOS .app export; got: " + export_path)
        return
    if not is_instance_valid(owner):
        push_error("Newt standalone export: Newt Play Bridge plugin is not active.")
        return
    var bundle_id := str(ProjectSettings.get_setting("newt/distribution/bundle_id", "")).strip_edges()
    if bundle_id.is_empty():
        bundle_id = owner._default_bundle_id()
    var game_app := export_path
    if not game_app.is_absolute_path():
        game_app = ProjectSettings.globalize_path(game_app)
    var output := game_app.get_base_dir().path_join(game_app.get_file().get_basename() + " (Newt-ready).app")
    var args := PackedStringArray(["bundle", "--game", game_app, "--output", output,
        "--runtime", runtime, "--bundle-id", bundle_id])
    var icd := str(ProjectSettings.get_setting("newt/distribution/icd_manifest", "")).strip_edges()
    if not icd.is_empty():
        args.append_array(["--icd", icd])
    var cli_output: Array = []
    var code: int = owner._run_cli(args, cli_output)
    var reply: Dictionary = owner._decode_response(code, cli_output)
    if not reply.get("ok", false):
        push_error("Newt standalone bundle failed. " + str(reply.get("error", "Unknown error")))
        return
    print("Newt: standalone bundle ready at " + str(reply.get("bundle", output)))
