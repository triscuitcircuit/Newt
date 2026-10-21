extends Node
# SPDX-License-Identifier: MIT
# Register only editor sessions prepared by the plugin. Standalone games without
# a token use their own launcher/runtime configuration and do nothing here.
func _daemon_path() -> String:
    var configured := str(ProjectSettings.get_setting("newt/executable", ""))
    if configured != "" and FileAccess.file_exists(configured):
        return configured
    for candidate in [OS.get_environment("HOME") + "/.local/bin/newtd", "/usr/local/bin/newtd", "/opt/homebrew/bin/newtd"]:
        if FileAccess.file_exists(candidate):
            return candidate
    # Keep in sync with plugin.gd's _daemon_path(): without this fallback, a
    # newtd installed only via a custom PATH prefix resolves for the editor
    # (plugin.gd), which stops the dashboard and issues a lease, but not for
    # the launched game (this autoload), which then never attaches -- the
    # session hangs until the lease times out with no indication why.
    var which_output: Array = []
    if OS.execute("/usr/bin/which", PackedStringArray(["newtd"]), which_output) == 0 and not which_output.is_empty():
        var found := str(which_output[0]).strip_edges()
        if found != "":
            return found
    return ""

func _enter_tree() -> void:
    if Engine.is_editor_hint() or not OS.has_environment("NEWT_LAUNCH_TOKEN"):
        return
    var attach := PackedStringArray([
        "attach",
        "--token", OS.get_environment("NEWT_LAUNCH_TOKEN"),
        "--pid", str(OS.get_process_id())])
    var output: Array = []
    var result := -1
    var daemon := _daemon_path()
    if daemon != "":
        result = OS.execute(daemon, attach, output, true)
    else:
        output.append("Newt: newtd not found; install Newt or set Project Settings > Newt > Executable.")
    if result != 0:
        push_error("Newt could not attach this game: " + "".join(output))
        get_tree().quit(1)
    # Newt monitors process exit, not scene exit: XR teardown finishes before
    # the dashboard is restarted, including on editor Stop or a game crash.
