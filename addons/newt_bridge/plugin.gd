@tool
extends EditorPlugin
# SPDX-License-Identifier: MIT

const AUTOLOAD = "NewtSessionBridge"
const ExportPlugin = preload("export_plugin.gd")
var export_plugin: EditorExportPlugin
var previous_environment: Dictionary = {}
var setup_dialog: ConfirmationDialog
var path_fields: Array[LineEdit] = []
var file_dialog: FileDialog
var selected_field := 0
var setup_message: Label

func _enter_tree() -> void:
    _setting("newt/executable", "", TYPE_STRING, PROPERTY_HINT_GLOBAL_FILE)
    _setting("newt/auto_start", true, TYPE_BOOL, PROPERTY_HINT_NONE)
    _setting("newt/distribution/runtime_manifest", "", TYPE_STRING, PROPERTY_HINT_GLOBAL_FILE)
    _setting("newt/distribution/icd_manifest", "", TYPE_STRING, PROPERTY_HINT_GLOBAL_FILE)
    _setting("newt/distribution/bundle_id", _default_bundle_id(), TYPE_STRING, PROPERTY_HINT_NONE)
    export_plugin = ExportPlugin.new()
    export_plugin.owner = self
    add_export_plugin(export_plugin)
    add_autoload_singleton(AUTOLOAD, "res://addons/newt_bridge/session.gd")
    add_tool_menu_item("Configure Newt…", _show_setup)
    setup_dialog = ConfirmationDialog.new()
    setup_dialog.title = "Configure Newt on this Mac"
    setup_dialog.ok_button_text = "Save configuration"
    get_editor_interface().get_base_control().add_child(setup_dialog)
    var layout := VBoxContainer.new()
    setup_dialog.add_child(layout)
    var labels := ["Newt dashboard executable (newt-demo)", "OpenXR runtime manifest (.json), not the loader dylib", "Vulkan ICD manifest (.json, optional)"]
    for i in range(3):
        var label := Label.new()
        label.text = labels[i]
        layout.add_child(label)
        var row := HBoxContainer.new()
        layout.add_child(row)
        var field := LineEdit.new()
        field.custom_minimum_size.x = 620
        field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
        row.add_child(field)
        path_fields.append(field)
        var browse := Button.new()
        browse.text = "Browse…"
        browse.pressed.connect(_browse.bind(i))
        row.add_child(browse)
    path_fields[0].text = OS.get_environment("HOME").path_join(".local/bin/newt-demo")
    path_fields[1].text = OS.get_environment("XR_RUNTIME_JSON")
    path_fields[2].text = OS.get_environment("VK_ICD_FILENAMES")
    setup_message = Label.new()
    setup_message.text = "Saved for this Mac. No headset session starts during setup."
    setup_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    setup_message.custom_minimum_size.x = 700
    layout.add_child(setup_message)
    setup_dialog.confirmed.connect(_save_setup)
    setup_dialog.dialog_hide_on_ok = false
    file_dialog = FileDialog.new()
    file_dialog.access = FileDialog.ACCESS_FILESYSTEM
    file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
    file_dialog.file_selected.connect(func(path: String): path_fields[selected_field].text = path)
    get_editor_interface().get_base_control().add_child(file_dialog)

func _setting(key: String, value: Variant, type: int, hint: int) -> void:
    if not ProjectSettings.has_setting(key):
        ProjectSettings.set_setting(key, value)
    ProjectSettings.add_property_info({"name": key, "type": type, "hint": hint})

func _default_bundle_id() -> String:
    var app_name := str(ProjectSettings.get_setting("application/config/name", "")).strip_edges().to_lower()
    var slug := ""
    for c in app_name:
        var u: int = c.unicode_at(0)
        slug += c if (u >= 97 and u <= 122) or (u >= 48 and u <= 57) else "-"
    while slug.contains("--"):
        slug = slug.replace("--", "-")
    slug = slug.trim_prefix("-").trim_suffix("-")
    return "org.newt." + (slug if not slug.is_empty() else "game")

func _exit_tree() -> void:
    if export_plugin != null:
        remove_export_plugin(export_plugin)
        export_plugin = null
    remove_tool_menu_item("Configure Newt…")
    if is_instance_valid(setup_dialog): setup_dialog.queue_free()
    if is_instance_valid(file_dialog): file_dialog.queue_free()
    remove_autoload_singleton(AUTOLOAD)
    for key in previous_environment:
        if previous_environment[key] == null:
            OS.unset_environment(key)
        else:
            OS.set_environment(key, previous_environment[key])

func _build() -> bool:
    if OS.get_name() != "macOS":
        push_error("Newt Play Bridge currently supports macOS only.")
        return false
    if not ProjectSettings.get_setting("xr/openxr/enabled", false) or not ProjectSettings.get_setting("xr/shaders/enabled", false):
        push_error("Enable XR > OpenXR and XR > Shaders, then restart the editor.")
        return false
    if ProjectSettings.get_setting("rendering/rendering_device/driver.macos", "") != "vulkan":
        push_error("Newt requires Rendering > Rendering Device > Driver > macOS = vulkan. Restart after changing it.")
        return false
    var args := PackedStringArray(["prepare"])
    if not ProjectSettings.get_setting("newt/auto_start", true):
        args.append("--no-start")
    var output: Array = []
    var code := _run_cli(args, output)
    var reply := _decode_response(code, output)
    if not reply.get("ok", false):
        push_error("Newt could not prepare the headset. " + str(reply.get("error", "Unknown error")))
        return false
    var environment: Dictionary = reply["environment"]
    environment["NEWT_LAUNCH_TOKEN"] = reply["token"]
    for key in environment:
        if not previous_environment.has(key):
            previous_environment[key] = OS.get_environment(key) if OS.has_environment(key) else null
        if str(environment[key]).is_empty():
            OS.unset_environment(key)
        else:
            OS.set_environment(key, str(environment[key]))
    ProjectSettings.save() # The child process must see the autoload registration.
    print("Newt: headset reserved; starting game. Dashboard returns after Stop.")
    return true

func _daemon_path() -> String:
    var configured := str(ProjectSettings.get_setting("newt/executable", ""))
    if configured != "" and FileAccess.file_exists(configured):
        return configured
    for candidate in [OS.get_environment("HOME") + "/.local/bin/newtd", "/usr/local/bin/newtd", "/opt/homebrew/bin/newtd"]:
        if FileAccess.file_exists(candidate):
            return candidate
    var which_output: Array = []
    if OS.execute("/usr/bin/which", PackedStringArray(["newtd"]), which_output) == 0 and not which_output.is_empty():
        var found := str(which_output[0]).strip_edges()
        if found != "":
            return found
    return ""

func _run_cli(arguments: PackedStringArray, output: Array) -> int:
    var daemon := _daemon_path()
    if daemon != "":
        return OS.execute(daemon, arguments, output, true)
    output.append("Newt: newtd not found. Install Newt (it provides ~/.local/bin/newtd) or set Project Settings > Newt > Executable.")
    return -1

func _decode_response(code: int, output: Array) -> Dictionary:
    var text := "".join(output).strip_edges()
    # Never feed a process error message to JSON.parse_string: it emits an
    # unrelated parser error that hides the actionable configuration failure.
    if code != 0:
        return {"ok": false, "error": text if not text.is_empty() else "Could not run the Newt session manager. Check Project Settings > Newt > Executable."}
    var parser := JSON.new()
    if parser.parse(text) != OK or not parser.data is Dictionary:
        return {"ok": false, "error": "Unexpected response from Newt: " + text}
    return parser.data

func _show_setup() -> void:
    setup_dialog.popup_centered(Vector2i(780, 340))

func _browse(index: int) -> void:
    selected_field = index
    file_dialog.filters = PackedStringArray(["*.json ; JSON manifest"]) if index > 0 else PackedStringArray()
    file_dialog.popup_centered_ratio(0.65)

func _save_setup() -> void:
    var args := PackedStringArray(["configure", "--dashboard", path_fields[0].text.strip_edges(), "--runtime", path_fields[1].text.strip_edges()])
    if not path_fields[2].text.strip_edges().is_empty():
        args.append_array(["--icd", path_fields[2].text.strip_edges()])
    var output: Array = []
    var code := _run_cli(args, output)
    var reply := _decode_response(code, output)
    if reply.get("ok", false):
        setup_message.text = "Saved. Press Play to start Newt. Restart an already-running Newt manager to apply changed paths."
    else:
        setup_message.text = str(reply.get("error", "Could not save configuration"))
