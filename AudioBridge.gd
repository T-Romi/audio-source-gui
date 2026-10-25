extends RefCounted

# Forward raw PCM from ADB's local TCP endpoint into the Linux audio FIFO.
# Godot manages the UI and lifecycle; the system Bash and cat commands carry audio.
const BRIDGE_SCRIPT := "user://audiosource_fifo_bridge.sh"

var _pid: int = -1
var _status_path := ""
var _stop_path := ""
var _status := "idle"
var _detail := ""
var _launch_time_msec := 0

const SCRIPT_TEXT := '''#!/bin/bash
set -u
PORT="$1"
FIFO="$2"
STATUS="$3"
STOP_FILE="$4"
CAT_PID=""
write_status() {
    local state="$1" detail="$2" tmp="${STATUS}.tmp.$$"
    printf '%s\\n%s\\n' "$state" "$detail" > "$tmp" && mv -f "$tmp" "$STATUS"
}
cleanup() {
    if [[ -n "$CAT_PID" ]]; then
        kill "$CAT_PID" 2>/dev/null || true
        wait "$CAT_PID" 2>/dev/null || true
        CAT_PID=""
    fi
    exec 3>&- 2>/dev/null || true
}
on_stop() {
    cleanup
    write_status stopped "Bridge stopped cleanly."
    exit 0
}
trap on_stop TERM INT HUP
write_status connecting "Connecting to ADB forwarded TCP port $PORT."
if ! exec 3<>"/dev/tcp/127.0.0.1/$PORT"; then
    write_status error "Could not connect to ADB forwarded TCP port $PORT."
    exit 1
fi
write_status socket_connected "Android audio socket connected; opening virtual microphone FIFO."
# cat opens the FIFO for writing and forwards bytes without interpreting PCM.
cat <&3 > "$FIFO" &
CAT_PID=$!
write_status connected "PCM forwarding active through Bash and cat."
wait "$CAT_PID"
RC=$?
CAT_PID=""
exec 3>&- 2>/dev/null || true
if [[ -e "$STOP_FILE" ]]; then
    write_status stopped "Bridge stopped cleanly."
else
    write_status closed "Android audio socket closed (bridge exit $RC)."
fi
exit 0
'''

func start(port: int, fifo_path: String) -> bool:
    stop()
    _status_path = fifo_path + ".bridge-status"
    _stop_path = _status_path + ".stop"
    _status = "connecting"
    _detail = "Starting the Bash TCP-to-FIFO bridge."
    _remove_status_files()

    var script_absolute := ProjectSettings.globalize_path(BRIDGE_SCRIPT)
    var script_file := FileAccess.open(BRIDGE_SCRIPT, FileAccess.WRITE)
    if script_file == null:
        _status = "error"
        _detail = "Could not create the temporary Bash bridge script in user data."
        return false
    script_file.store_string(SCRIPT_TEXT)
    script_file.close()

    var bash_path := "/bin/bash"
    if not FileAccess.file_exists(bash_path):
        _status = "error"
        _detail = "Bash was not found at /bin/bash."
        return false
    _pid = OS.create_process(bash_path, PackedStringArray([
        script_absolute, str(port), fifo_path, _status_path, _stop_path
    ]), false)
    if _pid <= 0:
        _status = "error"
        _detail = "Godot could not launch Bash for the TCP-to-FIFO bridge."
        _pid = -1
        return false
    _launch_time_msec = Time.get_ticks_msec()
    return true

func get_state() -> Dictionary:
    if not _status_path.is_empty() and FileAccess.file_exists(_status_path):
        var contents := FileAccess.get_file_as_string(_status_path)
        var lines := contents.split("\n", true)
        if not lines.is_empty() and not lines[0].is_empty():
            _status = lines[0].strip_edges()
            _detail = lines[1].strip_edges() if lines.size() > 1 else ""
    elif _pid > 0 and Time.get_ticks_msec() - _launch_time_msec > 2000 and _status not in ["closed", "error", "stopped"]:
        _status = "error"
        _detail = "The Bash bridge did not create its status file; check Bash and the audio FIFO."
    return {"status": _status, "detail": _detail}

func stop() -> void:
    var previous_pid := _pid
    if previous_pid > 0:
        # Signal the owned Bash process; its trap closes the TCP socket and kills cat.
        # Do not poll OS.is_process_running(): it can trigger waitpid/ECHILD logs.
        var stop_file := FileAccess.open(_stop_path, FileAccess.WRITE)
        if stop_file != null:
            stop_file.store_string("stop\n")
            stop_file.close()
        OS.kill(previous_pid)
        OS.delay_msec(100)
    _pid = -1
    _status = "stopped"
    _detail = ""
    _remove_status_files()

func _remove_status_files() -> void:
    for candidate in [_status_path, _stop_path, _status_path + ".tmp"]:
        if not candidate.is_empty() and FileAccess.file_exists(candidate):
            DirAccess.remove_absolute(candidate)
