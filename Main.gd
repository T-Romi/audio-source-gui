extends Control

const APP_TITLE := "Audio Source"
const GITHUB_URL := "https://github.com/gdzx/audiosource"
const PACKAGE_NAME := "fr.dzx.audiosource"
const ACTIVITY_NAME := "fr.dzx.audiosource/.MainActivity"
const SETTINGS_PATH := "user://settings.cfg"
const LOG_PATH := "user://audiosource-controller.log"
const SAMPLE_RATE := 44100
const FIFO_ROOT := "/tmp"
const AudioBridgeScript = preload("res://AudioBridge.gd")

const C_BG := Color("#0a1020")
const C_CARD := Color("#121d31")
const C_CARD_ALT := Color("#15243a")
const C_BORDER := Color("#263650")
const C_TEXT := Color("#f1f5f9")
const C_MUTED := Color("#94a3b8")
const C_TEAL := Color("#5eead4")
const C_TEAL_DARK := Color("#082f35")
const C_RED := Color("#fda4af")
const C_AMBER := Color("#fcd34d")

var serial_edit: LineEdit
var source_name_edit: LineEdit
var detect_button_ref: Button
var auto_restart_check: CheckBox
var volume_slider: HSlider
var volume_value_label: Label
var status_label: Label
var status_dot: Label
var status_pill: PanelContainer
var log_view: RichTextLabel
var requirements_label: Label
var phone_mic_label: Label

var adb_path := ""
var pactl_path := ""
var audio_bridge
var requirements_ok := false
var stream_active := false
var connection_ready := false
var active_source_name := ""
var active_module_id := ""
var fifo_path := ""
var previous_default_source := ""
var default_source_switched := false
var last_bridge_status := ""
var forward_port := -1
var volume_dragging := false
var reconnect_timer: Timer
var settings := ConfigFile.new()

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_window().min_size = Vector2i(760, 620)
	_build_ui()
	_load_settings()
	audio_bridge = AudioBridgeScript.new()
	_check_dependencies(true)
	_append_ui_log("Ready. Connect your phone, check the requirements, then start the virtual microphone.")
	reconnect_timer = Timer.new()
	reconnect_timer.one_shot = true
	reconnect_timer.wait_time = 1.0
	reconnect_timer.timeout.connect(_attempt_reconnect)
	add_child(reconnect_timer)
	_refresh_button_states()
	get_window().close_requested.connect(_on_close_requested)

func _build_ui() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = C_BG
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var root_margin := MarginContainer.new()
	root_margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root_margin.add_theme_constant_override("margin_left", 22)
	root_margin.add_theme_constant_override("margin_right", 22)
	root_margin.add_theme_constant_override("margin_top", 18)
	root_margin.add_theme_constant_override("margin_bottom", 18)
	add_child(root_margin)

	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 10)
	root_margin.add_child(page)
	page.add_child(_build_header())
	page.add_child(_make_divider())

	# One compact column: device, source name, phone status, controls, volume, log.
	var device_panel := _make_panel()
	page.add_child(device_panel)
	var device_box := VBoxContainer.new()
	device_box.add_theme_constant_override("separation", 8)
	device_panel.add_child(device_box)

	var device_title := Label.new()
	device_title.text = "Device"
	device_title.add_theme_font_size_override("font_size", 16)
	device_title.add_theme_color_override("font_color", C_TEXT)
	device_box.add_child(device_title)

	var device_row := HBoxContainer.new()
	device_row.add_theme_constant_override("separation", 8)
	device_box.add_child(device_row)
	serial_edit = _make_line_edit("Android serial (auto-detect if only one device)")
	serial_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	serial_edit.text_submitted.connect(func(_value: String) -> void: _save_settings())
	serial_edit.focus_exited.connect(_save_settings)
	device_row.add_child(serial_edit)
	detect_button_ref = _make_button("Detect", "secondary")
	detect_button_ref.pressed.connect(_on_detect_devices_pressed)
	device_row.add_child(detect_button_ref)

	var source_row := HBoxContainer.new()
	source_row.add_theme_constant_override("separation", 8)
	device_box.add_child(source_row)
	var source_caption := Label.new()
	source_caption.text = "Source name"
	source_caption.custom_minimum_size.x = 102
	source_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	source_caption.add_theme_color_override("font_color", C_MUTED)
	source_caption.add_theme_font_size_override("font_size", 12)
	source_row.add_child(source_caption)
	source_name_edit = _make_line_edit("Optional — generated automatically")
	source_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	source_name_edit.custom_minimum_size.y = 36
	source_name_edit.text_submitted.connect(func(_value: String) -> void: _save_settings())
	source_name_edit.focus_exited.connect(_save_settings)
	source_row.add_child(source_name_edit)

	var phone_status_panel := PanelContainer.new()
	phone_status_panel.add_theme_stylebox_override("panel", _flat_style(Color("#0d192a"), Color("#263b53"), 10, 1))
	page.add_child(phone_status_panel)
	phone_mic_label = Label.new()
	phone_mic_label.text = "Phone microphone: Off — press Start to activate Audio Source on the phone."
	phone_mic_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	phone_mic_label.add_theme_font_size_override("font_size", 12)
	phone_mic_label.add_theme_color_override("font_color", C_MUTED)
	phone_status_panel.add_child(phone_mic_label)

	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	page.add_child(action_row)
	var start_button := _make_button("Start microphone", "primary")
	start_button.name = "StartButton"
	start_button.custom_minimum_size.y = 46
	start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	start_button.pressed.connect(_on_start_pressed)
	action_row.add_child(start_button)
	var stop_button := _make_button("Stop", "danger")
	stop_button.name = "StopButton"
	stop_button.custom_minimum_size.y = 46
	stop_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stop_button.pressed.connect(_on_stop_pressed)
	action_row.add_child(stop_button)

	var options_row := HBoxContainer.new()
	options_row.add_theme_constant_override("separation", 12)
	page.add_child(options_row)
	auto_restart_check = CheckBox.new()
	auto_restart_check.text = "Reconnect automatically"
	auto_restart_check.add_theme_color_override("font_color", C_TEXT)
	auto_restart_check.add_theme_font_size_override("font_size", 12)
	auto_restart_check.toggled.connect(func(_pressed: bool) -> void: _save_settings())
	options_row.add_child(auto_restart_check)
	var requirements_button := _make_button("Check requirements", "outline")
	requirements_button.pressed.connect(_on_check_dependencies_pressed)
	options_row.add_child(requirements_button)
	requirements_label = Label.new()
	requirements_label.text = "Checking requirements…"
	requirements_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	requirements_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	requirements_label.add_theme_font_size_override("font_size", 10)
	requirements_label.add_theme_color_override("font_color", C_MUTED)
	options_row.add_child(requirements_label)

	var volume_panel := _make_panel()
	page.add_child(volume_panel)
	var volume_box := VBoxContainer.new()
	volume_box.add_theme_constant_override("separation", 6)
	volume_panel.add_child(volume_box)
	var volume_header := HBoxContainer.new()
	volume_box.add_child(volume_header)
	var volume_title := Label.new()
	volume_title.text = "Virtual microphone volume"
	volume_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	volume_title.add_theme_font_size_override("font_size", 14)
	volume_title.add_theme_color_override("font_color", C_TEXT)
	volume_header.add_child(volume_title)
	volume_value_label = Label.new()
	volume_value_label.text = "100%"
	volume_value_label.add_theme_font_size_override("font_size", 17)
	volume_value_label.add_theme_color_override("font_color", C_TEAL)
	volume_header.add_child(volume_value_label)
	volume_slider = HSlider.new()
	volume_slider.min_value = 0
	volume_slider.max_value = 400
	volume_slider.step = 5
	volume_slider.value = 100
	volume_slider.custom_minimum_size.y = 24
	volume_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	volume_slider.tooltip_text = "0% mutes the virtual microphone; 100% is normal; higher values boost it."
	volume_slider.value_changed.connect(_on_volume_changed)
	volume_slider.drag_started.connect(_on_volume_drag_started)
	volume_slider.drag_ended.connect(_on_volume_drag_ended)
	volume_box.add_child(volume_slider)
	var volume_range := Label.new()
	volume_range.text = "0% = mute   ·   100% = normal   ·   400% = maximum boost"
	volume_range.add_theme_font_size_override("font_size", 10)
	volume_range.add_theme_color_override("font_color", C_MUTED)
	volume_box.add_child(volume_range)

	var log_panel := _make_panel(Color("#0d1525"), Color("#263650"))
	log_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_panel.custom_minimum_size.y = 110
	page.add_child(log_panel)
	var log_box := VBoxContainer.new()
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_box.add_theme_constant_override("separation", 5)
	log_panel.add_child(log_box)
	var log_header := HBoxContainer.new()
	log_box.add_child(log_header)
	var log_title := Label.new()
	log_title.text = "Activity"
	log_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_title.add_theme_font_size_override("font_size", 13)
	log_title.add_theme_color_override("font_color", C_TEXT)
	log_header.add_child(log_title)
	var clear_button := _make_button("Clear", "outline")
	clear_button.custom_minimum_size.y = 28
	clear_button.pressed.connect(_on_clear_log_pressed)
	log_header.add_child(clear_button)
	log_view = RichTextLabel.new()
	log_view.bbcode_enabled = false
	log_view.selection_enabled = true
	log_view.scroll_following = true
	log_view.fit_content = false
	log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_view.custom_minimum_size.y = 62
	log_view.add_theme_color_override("default_color", Color("#cbd5e1"))
	log_view.add_theme_font_size_override("normal_font_size", 11)
	log_box.add_child(log_view)

	var footer := Label.new()
	footer.text = "Start activates the phone's Audio Source recorder; Android shows its microphone indicator while recording."
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	footer.add_theme_font_size_override("font_size", 10)
	footer.add_theme_color_override("font_color", Color("#64748b"))
	page.add_child(footer)

func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)

	var logo := PanelContainer.new()
	logo.custom_minimum_size = Vector2(52, 52)
	logo.add_theme_stylebox_override("panel", _flat_style(Color("#123b43"), Color("#1a726f"), 15, 1))
	header.add_child(logo)
	var logo_label := Label.new()
	logo_label.text = "AS"
	logo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	logo_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	logo_label.add_theme_font_size_override("font_size", 19)
	logo_label.add_theme_color_override("font_color", C_TEAL)
	logo.add_child(logo_label)

	var identity := VBoxContainer.new()
	identity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	identity.add_theme_constant_override("separation", 1)
	header.add_child(identity)
	var title := Label.new()
	title.text = APP_TITLE
	title.add_theme_font_size_override("font_size", 25)
	title.add_theme_color_override("font_color", C_TEXT)
	identity.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "LINUX DESKTOP CONTROLLER"
	subtitle.add_theme_font_size_override("font_size", 10)
	subtitle.add_theme_color_override("font_color", C_MUTED)
	identity.add_child(subtitle)

	status_pill = PanelContainer.new()
	status_pill.add_theme_stylebox_override("panel", _flat_style(Color("#182a35"), Color("#2a4b56"), 18, 1))
	header.add_child(status_pill)
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 7)
	status_pill.add_child(status_row)
	status_dot = Label.new()
	status_dot.text = "●"
	status_dot.add_theme_color_override("font_color", C_TEAL)
	status_row.add_child(status_dot)
	status_label = Label.new()
	status_label.text = "READY"
	status_label.add_theme_font_size_override("font_size", 11)
	status_label.add_theme_color_override("font_color", C_TEXT)
	status_row.add_child(status_label)

	var github_button := _make_button("GitHub  ↗", "outline")
	github_button.tooltip_text = "Open the Audio Source project on GitHub"
	github_button.pressed.connect(_on_github_pressed)
	header.add_child(github_button)
	return header

func _make_line_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.clear_button_enabled = true
	edit.custom_minimum_size.y = 40
	edit.add_theme_color_override("font_color", C_TEXT)
	edit.add_theme_color_override("font_placeholder_color", Color("#64748b"))
	edit.add_theme_stylebox_override("normal", _flat_style(Color("#0b1424"), Color("#2b3b53"), 8, 1))
	edit.add_theme_stylebox_override("focus", _flat_style(Color("#0b1424"), C_TEAL, 8, 1))
	return edit

func _make_panel(background_color: Color = C_CARD, border_color: Color = C_BORDER) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat_style(background_color, border_color, 14, 1))
	return panel

func _flat_style(background_color: Color, border_color: Color, radius: int, border_width: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background_color
	style.border_color = border_color
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	return style

func _make_button(text_value: String, variant: String = "secondary") -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size.y = 39
	button.add_theme_font_size_override("font_size", 12)
	button.focus_mode = Control.FOCUS_ALL
	var normal_color := Color("#1c2a40")
	var hover_color := Color("#273954")
	var pressed_color := Color("#162338")
	var text_color := C_TEXT
	var border_color := Color("#354962")
	if variant == "primary":
		normal_color = C_TEAL
		hover_color = Color("#99f6e4")
		pressed_color = Color("#2dd4bf")
		text_color = C_TEAL_DARK
		border_color = C_TEAL
	elif variant == "danger":
		normal_color = Color("#35202d")
		hover_color = Color("#4a2637")
		pressed_color = Color("#281925")
		text_color = C_RED
		border_color = Color("#633246")
	elif variant == "outline":
		normal_color = Color("#121d31")
		hover_color = Color("#1e3048")
		pressed_color = Color("#0f192a")
		text_color = C_TEAL
		border_color = Color("#315365")
	button.add_theme_color_override("font_color", text_color)
	button.add_theme_color_override("font_hover_color", text_color)
	button.add_theme_color_override("font_pressed_color", text_color)
	button.add_theme_color_override("font_disabled_color", Color("#64748b"))
	button.add_theme_stylebox_override("normal", _flat_style(normal_color, border_color, 9, 1))
	button.add_theme_stylebox_override("hover", _flat_style(hover_color, border_color, 9, 1))
	button.add_theme_stylebox_override("pressed", _flat_style(pressed_color, border_color, 9, 1))
	button.add_theme_stylebox_override("disabled", _flat_style(Color("#182235"), Color("#28364b"), 9, 1))
	return button

func _make_divider() -> Control:
	var line := ColorRect.new()
	line.color = Color("#213149")
	line.custom_minimum_size.y = 1
	return line

func _load_settings() -> void:
	var load_result := settings.load(SETTINGS_PATH)
	var environment_serial := OS.get_environment("ANDROID_SERIAL").strip_edges()
	var environment_source_name := OS.get_environment("AUDIOSOURCE_NAME").strip_edges()
	var saved_serial := "" if load_result != OK else str(settings.get_value("general", "serial", ""))
	var saved_source_name := "" if load_result != OK else str(settings.get_value("general", "source_name", ""))
	serial_edit.text = saved_serial if not saved_serial.is_empty() else environment_serial
	source_name_edit.text = saved_source_name if not saved_source_name.is_empty() else environment_source_name
	auto_restart_check.button_pressed = false if load_result != OK else bool(settings.get_value("general", "auto_restart", false))
	volume_slider.value = clampf(100.0 if load_result != OK else float(settings.get_value("general", "volume", 100)), 0.0, 400.0)
	volume_value_label.text = "%d%%" % int(round(volume_slider.value))
	_apply_source_volume()

func _save_settings() -> void:
	if serial_edit == null:
		return
	settings.set_value("general", "serial", serial_edit.text.strip_edges())
	settings.set_value("general", "source_name", source_name_edit.text.strip_edges())
	settings.set_value("general", "auto_restart", auto_restart_check.button_pressed)
	settings.set_value("general", "volume", volume_slider.value)
	settings.save(SETTINGS_PATH)

func _serial() -> String:
	return serial_edit.text.strip_edges()

func _source_name() -> String:
	return source_name_edit.text.strip_edges()

func _effective_source_name() -> String:
	var entered := _source_name()
	if not entered.is_empty():
		return entered
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(_serial().to_utf8_buffer())
	return "android-" + hasher.finish().hex_encode().substr(0, 7)

func _resolve_executable(command_name: String) -> String:
	var path_value := OS.get_environment("PATH")
	for directory in path_value.split(":", false):
		var candidate := directory.path_join(command_name)
		if FileAccess.file_exists(candidate):
			return candidate
	var home := OS.get_environment("HOME")
	var candidates := PackedStringArray()
	match command_name:
		"adb":
			candidates = PackedStringArray([
				"/usr/bin/adb",
				"/usr/local/bin/adb",
				"/usr/lib/android-sdk/platform-tools/adb",
				home.path_join("Android/Sdk/platform-tools/adb"),
				home.path_join(".android-sdk/platform-tools/adb")
			])
		"pactl":
			candidates = PackedStringArray(["/usr/bin/pactl", "/usr/local/bin/pactl"])
	for candidate in candidates:
		if not candidate.is_empty() and FileAccess.file_exists(candidate):
			return candidate
	return ""

func _execute_program(program_path: String, arguments: PackedStringArray) -> Dictionary:
	if program_path.is_empty():
		return {"code": 127, "output": "Executable was not found"}
	var output: Array = []
	var code: int = OS.execute(program_path, arguments, output, true)
	var combined := ""
	for output_part in output:
		combined += str(output_part)
	return {"code": code, "output": combined.strip_edges()}

func _is_valid_source_name(value: String) -> bool:
	if value.is_empty() or value.length() > 64:
		return false
	for index in range(value.length()):
		var character := value.substr(index, 1)
		if not ((character >= "a" and character <= "z") or (character >= "A" and character <= "Z") or (character >= "0" and character <= "9") or character == "-" or character == "_" or character == "."):
			return false
	return true

func _execute_adb(arguments: PackedStringArray, use_device: bool = true) -> Dictionary:
	if adb_path.is_empty():
		return {"code": 127, "output": "adb was not found"}
	var final_arguments := PackedStringArray()
	if use_device:
		var selected := _serial()
		if selected.is_empty():
			return {"code": 2, "output": "No device serial selected"}
		final_arguments.append("-s")
		final_arguments.append(selected)
	final_arguments.append_array(arguments)
	var output: Array = []
	var code: int = OS.execute(adb_path, final_arguments, output, true)
	var combined := ""
	for output_part in output:
		combined += str(output_part)
	return {"code": code, "output": combined.strip_edges()}

func _check_dependencies(log_results: bool = true) -> bool:
	adb_path = _resolve_executable("adb")
	pactl_path = _resolve_executable("pactl")
	var failures: Array[String] = []
	if adb_path.is_empty():
		failures.append("adb not found")
	else:
		var adb_result := _execute_program(adb_path, PackedStringArray(["version"]))
		if int(adb_result["code"]) != 0 or not str(adb_result["output"]).to_lower().contains("android debug bridge"):
			failures.append("adb cannot run: " + str(adb_result["output"]))
	if pactl_path.is_empty():
		failures.append("pactl not found (needed to create the virtual microphone)")
	else:
		var audio_server_result := _execute_program(pactl_path, PackedStringArray(["info"]))
		if int(audio_server_result["code"]) != 0:
			failures.append("pactl cannot reach a PulseAudio-compatible server: " + str(audio_server_result["output"]))
	var bash_path := _resolve_executable("bash")
	var cat_path := _resolve_executable("cat")
	if bash_path.is_empty():
		failures.append("bash not found (needed for TCP-to-FIFO forwarding)")
	if cat_path.is_empty():
		failures.append("cat not found (needed to copy raw PCM into the FIFO)")
	requirements_ok = failures.is_empty()
	var report := "[OK] Required commands found and the audio server is reachable." if requirements_ok else "[ERROR] Requirements check failed: " + "; ".join(PackedStringArray(failures))
	if requirements_label != null:
		if requirements_ok:
			requirements_label.text = "Ready: adb, pactl, bash, cat, and a running PulseAudio/PipeWire-Pulse server."
			requirements_label.add_theme_color_override("font_color", C_TEAL)
		else:
			requirements_label.text = "Missing or unavailable: " + "; ".join(PackedStringArray(failures))
			requirements_label.add_theme_color_override("font_color", C_RED)
	if log_results:
		_append_ui_log(report)
	if not stream_active:
		_set_status("Requirements ready" if requirements_ok else "Requirements missing", requirements_ok)
	_refresh_button_states()
	return requirements_ok

func _on_check_dependencies_pressed() -> void:
	_append_ui_log("Checking ADB, pactl and the audio server…")
	_check_dependencies(true)

func _list_devices() -> Dictionary:
	var result := _execute_adb(PackedStringArray(["devices", "-l"]), false)
	var connected: Array[String] = []
	var unauthorized: Array[String] = []
	if int(result["code"]) != 0:
		return {"code": int(result["code"]), "output": str(result["output"]), "connected": connected, "unauthorized": unauthorized}
	for raw_line in str(result["output"]).split("\n"):
		var line := raw_line.strip_edges().replace("\t", " ")
		if line.is_empty() or line.begins_with("List of devices") or line.begins_with("*"):
			continue
		var parts := line.split(" ", false)
		if parts.size() < 2:
			continue
		if parts[1] == "device":
			connected.append(parts[0])
		elif parts[1] == "unauthorized":
			unauthorized.append(parts[0])
	return {"code": 0, "output": str(result["output"]), "connected": connected, "unauthorized": unauthorized}

func _ensure_device_ready() -> bool:
	if not _check_dependencies(false):
		_set_status("Requirements missing", false)
		_append_ui_log("ERROR: One or more runtime requirements are unavailable. Check the System Requirements panel.")
		return false
	var device_result := _list_devices()
	if int(device_result["code"]) != 0:
		_set_status("ADB failed", false)
		_append_ui_log("ERROR: adb devices failed: " + str(device_result["output"]))
		return false
	var connected: Array = device_result["connected"]
	var unauthorized: Array = device_result["unauthorized"]
	var selected := _serial()
	if selected.is_empty():
		if connected.size() == 1:
			selected = str(connected[0])
			serial_edit.text = selected
			_save_settings()
		elif connected.is_empty():
			_set_status("No authorized device", false)
			_append_ui_log("ERROR: No authorized Android device. Connect it, enable USB debugging, and accept the debugging prompt.")
			if not unauthorized.is_empty():
				_append_ui_log("Found an unauthorized device: " + ", ".join(PackedStringArray(unauthorized)))
			return false
		else:
			_set_status("Select device", false)
			_append_ui_log("ERROR: Multiple devices are connected. Enter the desired serial or select one after Detect.")
			return false
	elif not connected.has(selected):
		_set_status("Device unavailable", false)
		if unauthorized.has(selected):
			_append_ui_log("ERROR: Device %s is unauthorized. Unlock it and accept the USB debugging prompt." % selected)
		else:
			_append_ui_log("ERROR: Device %s is not connected or authorized. Click Detect." % selected)
		return false

	var package_result := _execute_adb(PackedStringArray(["shell", "pm", "path", PACKAGE_NAME]))
	if int(package_result["code"]) != 0 or not str(package_result["output"]).contains("package:"):
		_set_status("App not installed", false)
		_append_ui_log("ERROR: Audio Source app is not installed on %s. Get it from %s" % [selected, GITHUB_URL])
		return false
	var permission_dump_result := _execute_adb(PackedStringArray(["shell", "dumpsys", "package", PACKAGE_NAME]))
	if int(permission_dump_result["code"]) != 0:
		_set_status("Permission check failed", false)
		_append_ui_log("ERROR: Could not inspect Audio Source permissions: " + str(permission_dump_result["output"]))
		return false
	var permission_dump := str(permission_dump_result["output"])
	var missing_permissions: Array[String] = []
	for permission in ["android.permission.POST_NOTIFICATIONS", "android.permission.RECORD_AUDIO"]:
		if _permission_is_granted(permission_dump, permission):
			continue
		_append_ui_log("Permission not granted yet: " + permission + ". Trying ADB grant…")
		var permission_result := _execute_adb(PackedStringArray(["shell", "pm", "grant", PACKAGE_NAME, permission]))
		permission_dump_result = _execute_adb(PackedStringArray(["shell", "dumpsys", "package", PACKAGE_NAME]))
		permission_dump = str(permission_dump_result["output"])
		if _permission_is_granted(permission_dump, permission):
			_append_ui_log("Permission granted: " + permission)
		else:
			missing_permissions.append(permission)
			_append_ui_log("Permission could not be granted automatically: " + permission + ". ADB output: " + str(permission_result["output"]))
	if not missing_permissions.is_empty():
		_set_status("Permissions needed", false)
		_append_ui_log("ERROR: Required Android permissions are missing: " + ", ".join(PackedStringArray(missing_permissions)))
		_append_ui_log("Please grant them manually, then retry: https://guidebooks.google.com/android/changesettingspermissions/changeyourapppermissions")
		return false
	_append_ui_log("Device ready: %s; Audio Source app is installed and required permissions are granted." % selected)
	return true

func _permission_is_granted(package_dump: String, permission: String) -> bool:
	for line in package_dump.split("\n"):
		if line.contains(permission) and line.contains("granted=true"):
			return true
	return false

func _on_detect_devices_pressed() -> void:
	if not _check_dependencies(false):
		_set_status("Requirements missing", false)
		_append_ui_log("ERROR: One or more runtime requirements are unavailable. Check the System Requirements panel.")
		return
	var result := _list_devices()
	if int(result["code"]) != 0:
		_set_status("ADB failed", false)
		_append_ui_log("ERROR: adb devices failed: " + str(result["output"]))
		return
	_append_ui_log("Device scan:\n" + str(result["output"]))
	var connected: Array = result["connected"]
	var unauthorized: Array = result["unauthorized"]
	if connected.size() == 1:
		serial_edit.text = str(connected[0])
		_append_ui_log("Selected device: " + serial_edit.text)
		_set_status("Device detected", true)
	elif connected.size() > 1:
		if not _serial().is_empty() and connected.has(_serial()):
			_append_ui_log("Selected device is connected: " + _serial())
			_set_status("Device selected", true)
		else:
			_append_ui_log("Multiple authorized devices found. Enter the serial you want to use.")
			_set_status("Select a device", false)
	elif not unauthorized.is_empty():
		_append_ui_log("Device found but unauthorized. Unlock it and accept the USB debugging prompt.")
		_set_status("Authorize device", false)
	else:
		_append_ui_log("No authorized device found. Connect the device and enable USB debugging.")
		_set_status("No device found", false)
	_save_settings()

func _on_start_pressed() -> void:
	if stream_active:
		return
	if not _check_dependencies(false):
		_set_status("Requirements missing", false)
		_append_ui_log("ERROR: Start blocked. The virtual-microphone workflow requires adb, pactl, and a reachable PulseAudio-compatible server.")
		return
	if not _ensure_device_ready():
		return
	_save_settings()
	active_source_name = _effective_source_name()
	if not _is_valid_source_name(active_source_name):
		_set_status("Invalid source name", false)
		_append_ui_log("ERROR: Source name must be 1–64 characters containing only letters, numbers, dots, dashes, or underscores.")
		return
	fifo_path = FIFO_ROOT.path_join(active_source_name)
	active_module_id = ""
	forward_port = -1
	last_bridge_status = ""
	connection_ready = false
	stream_active = true
	_set_status("Preparing virtual mic", true)
	_set_phone_mic_status("Phone microphone: Starting when the session launches…", "starting")
	_append_ui_log("Starting virtual microphone from %s…" % _serial())
	_append_ui_log("Virtual source name: " + active_source_name)
	_append_ui_log("Creating module-pipe-source (mono, signed 16-bit PCM, 44.1 kHz).")
	_refresh_button_states()
	if not _create_virtual_source():
		_finish_stream("Could not create the virtual microphone. Check pactl and the audio-server log.")
		return
	var opened := await _open_audio_transport(false)
	if not stream_active:
		return
	if not opened:
		if auto_restart_check.button_pressed:
			_schedule_reconnect("Initial bridge startup failed; retrying in 1 second.")
		else:
			_finish_stream("Could not start the Android-to-virtual-microphone bridge.")
	_refresh_button_states()

func _create_virtual_source() -> bool:
	# Remember the desktop's current input before replacing any stale instance
	# of our own source. If that stale source was the default, re-read the
	# server-selected fallback after removing it.
	var default_before_cleanup := _get_default_source()
	_unload_source_by_name(active_source_name)
	previous_default_source = default_before_cleanup
	if previous_default_source == active_source_name:
		previous_default_source = _get_default_source()
	if previous_default_source == active_source_name:
		previous_default_source = ""
	default_source_switched = false

	var load_result := _execute_program(pactl_path, PackedStringArray([
		"load-module", "module-pipe-source",
		"source_name=" + active_source_name,
		"channels=1", "format=s16", "rate=44100",
		"file=" + fifo_path
	]))
	if int(load_result["code"]) != 0 or str(load_result["output"]).strip_edges().is_empty():
		_append_ui_log("ERROR: pactl could not load module-pipe-source: " + str(load_result["output"]))
		return false
	var module_ids := str(load_result["output"]).strip_edges().split(" ", false)
	if module_ids.is_empty():
		_append_ui_log("ERROR: pactl returned no virtual source module ID.")
		return false
	active_module_id = str(module_ids[0])
	_append_ui_log("Virtual microphone created (PulseAudio module ID %s)." % active_module_id)

	# Make the phone microphone the desktop-wide default input automatically.
	var default_result := _execute_program(pactl_path, PackedStringArray(["set-default-source", active_source_name]))
	if int(default_result["code"]) == 0:
		var confirmed_default := _get_default_source()
		if confirmed_default == active_source_name:
			default_source_switched = true
			_append_ui_log("System default input switched to the phone microphone (%s). Apps using the default input will use phone audio." % active_source_name)
		else:
			_append_ui_log("WARNING: pactl accepted the default-input change, but couldn't confirm it. Current default: %s" % (confirmed_default if not confirmed_default.is_empty() else "unknown"))
	else:
		_append_ui_log("WARNING: Could not switch the system default input to the phone microphone: " + str(default_result["output"]))
	_apply_source_volume()
	return true

func _get_default_source() -> String:
	if pactl_path.is_empty():
		return ""
	var info_result := _execute_program(pactl_path, PackedStringArray(["info"]))
	if int(info_result["code"]) != 0:
		return ""
	for line in str(info_result["output"]).split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("Default Source:"):
			var source_name := trimmed.substr("Default Source:".length()).strip_edges()
			return "" if source_name.is_empty() or source_name.to_lower() == "n/a" else source_name
	return ""

func _restore_previous_default_source() -> void:
	if not default_source_switched:
		previous_default_source = ""
		return
	var current_default := _get_default_source()
	# Don't override a different input the user or another app selected while
	# streaming. Only restore our previous value while our virtual source is
	# still selected (or if the server can't report the current default).
	if not current_default.is_empty() and current_default != active_source_name:
		_append_ui_log("Default input is now %s; leaving that newer selection unchanged." % current_default)
	elif previous_default_source.is_empty():
		_append_ui_log("No previous default input was recorded; the audio server will choose a fallback when the virtual microphone is removed.")
	else:
		var restore_result := _execute_program(pactl_path, PackedStringArray(["set-default-source", previous_default_source]))
		if int(restore_result["code"]) == 0:
			_append_ui_log("Restored previous system input: %s." % previous_default_source)
		else:
			_append_ui_log("WARNING: Could not restore previous system input %s: %s" % [previous_default_source, str(restore_result["output"])])
	default_source_switched = false
	previous_default_source = ""

func _unload_source_by_name(source_name: String) -> void:
	if pactl_path.is_empty() or source_name.is_empty():
		return
	var list_result := _execute_program(pactl_path, PackedStringArray(["list", "modules", "short"]))
	if int(list_result["code"]) != 0:
		_append_ui_log("WARNING: Could not inspect existing PulseAudio modules: " + str(list_result["output"]))
		return
	for line in str(list_result["output"]).split("\n"):
		var fields := line.strip_edges().split("\t", false)
		if fields.size() < 3 or fields[1] != "module-pipe-source":
			continue
		var args: String = line
		var source_key := "source_name=" + source_name
		var key_position := args.find(source_key)
		if key_position >= 0:
			var after_key := args.substr(key_position + source_key.length(), 1)
			if not (after_key.is_empty() or after_key == " " or after_key == "\t"):
				continue
			var unload_result := _execute_program(pactl_path, PackedStringArray(["unload-module", fields[0]]))
			if int(unload_result["code"]) == 0:
				_append_ui_log("Removed previous virtual source instance %s." % fields[0])
			else:
				_append_ui_log("WARNING: Could not remove previous source instance: " + str(unload_result["output"]))

func _open_audio_transport(reconnecting: bool = false) -> bool:
	if not stream_active:
		return false
	_stop_bridge_process()
	_remove_audio_forward()
	var launch_result := _execute_adb(PackedStringArray(["shell", "am", "start", "-n", ACTIVITY_NAME]))
	if int(launch_result["code"]) != 0:
		_set_phone_mic_status("Phone microphone: Could not start Audio Source on the phone.", "error")
		_append_ui_log("ERROR: Could not start Audio Source activity: " + str(launch_result["output"]))
		return false
	_set_phone_mic_status("Phone microphone: Starting on Android…", "starting")
	_append_ui_log("Audio Source was launched on the phone. Android should show its microphone privacy indicator/recording notification while the recorder is active.")

	# Godot exposes TCP streams but not Linux abstract-namespace UNIX sockets.
	# ADB keeps the Android-side localabstract socket unchanged and allocates a local TCP port.
	var forward_result := _execute_adb(PackedStringArray(["forward", "tcp:0", "localabstract:audiosource"]))
	if int(forward_result["code"]) != 0:
		_append_ui_log("ERROR: ADB TCP forwarding failed: " + str(forward_result["output"]))
		return false
	var port_text := str(forward_result["output"]).strip_edges()
	if not port_text.is_valid_int():
		_append_ui_log("ERROR: ADB did not return the allocated TCP port: " + port_text)
		return false
	forward_port = int(port_text)
	if forward_port < 1 or forward_port > 65535:
		_append_ui_log("ERROR: ADB returned an invalid TCP port: " + port_text)
		_remove_audio_forward()
		return false
	_append_ui_log("ADB forwarding active on 127.0.0.1:%d → Android localabstract:audiosource." % forward_port)
	var ready_delay := 1.0 if not reconnecting else 0.5
	_append_ui_log("Waiting %.1f second(s) for Android audio startup…" % ready_delay)
	await get_tree().create_timer(ready_delay).timeout
	if not stream_active:
		_remove_audio_forward()
		return false
	if not audio_bridge.start(forward_port, fifo_path):
		_append_ui_log("ERROR: Could not start the socket-to-FIFO bridge.")
		_remove_audio_forward()
		return false
	connection_ready = false
	last_bridge_status = "connecting"
	_set_status("Connecting virtual mic", true)
	_append_ui_log("Audio bridge started; waiting for the Android socket and virtual microphone FIFO…")
	return true

func _process(_delta: float) -> void:
	if not stream_active or audio_bridge == null:
		return
	var bridge_info: Dictionary = audio_bridge.get_state()
	var status := str(bridge_info.get("status", "idle"))
	if status == last_bridge_status:
		return
	last_bridge_status = status
	if status == "connected":
		connection_ready = true
		_set_phone_mic_status("Phone microphone: Active on Android · virtual mic connected.", "active")
		_set_status("Virtual mic active", true)
		_append_ui_log("Bridge connected to the virtual microphone. Audio is available as an input to OBS and other applications.")
		_apply_source_volume()
		_refresh_button_states()
	elif status == "socket_connected":
		_set_status("Connecting FIFO", true)
		_append_ui_log("Android audio socket connected; opening the virtual-source FIFO…")
	elif status == "connecting":
		_set_status("Connecting virtual mic", true)
	elif status == "closed" or status == "error":
		var reason := str(bridge_info.get("detail", ""))
		if reason.is_empty():
			reason = "The Android audio connection closed." if status == "closed" else "The audio bridge failed."
		_handle_connection_lost(reason)

func _handle_connection_lost(reason: String) -> void:
	if not stream_active:
		return
	connection_ready = false
	_stop_bridge_process()
	_remove_audio_forward()
	if auto_restart_check.button_pressed:
		_schedule_reconnect(reason + " Retrying in 1 second.")
	else:
		_finish_stream(reason)

func _schedule_reconnect(message: String) -> void:
	if not stream_active:
		return
	_set_phone_mic_status("Phone microphone: Recording on Android; reconnecting desktop audio link…", "active")
	_append_ui_log(message)
	_set_status("Reconnecting", false)
	if reconnect_timer != null:
		reconnect_timer.start(1.0)

func _attempt_reconnect() -> void:
	if not stream_active:
		return
	_append_ui_log("Reconnecting Android audio to the existing virtual microphone…")
	var opened: bool = await _open_audio_transport(true)
	if not stream_active:
		return
	if not opened and reconnect_timer != null:
		reconnect_timer.start(1.0)

func _remove_audio_forward() -> void:
	if adb_path != "" and not _serial().is_empty() and forward_port > 0:
		var remove_result := _execute_adb(PackedStringArray(["forward", "--remove", "tcp:" + str(forward_port)]))
		if int(remove_result["code"]) != 0:
			_append_ui_log("WARNING: Could not remove ADB TCP forward: " + str(remove_result["output"]))
		forward_port = -1

func _stop_bridge_process() -> void:
	if audio_bridge != null:
		audio_bridge.stop()
	last_bridge_status = ""

func _finish_stream(reason: String) -> void:
	stream_active = false
	connection_ready = false
	if reconnect_timer != null:
		reconnect_timer.stop()
	_stop_bridge_process()
	_remove_audio_forward()
	_restore_previous_default_source()
	if not active_module_id.is_empty() and not pactl_path.is_empty():
		var unload_result := _execute_program(pactl_path, PackedStringArray(["unload-module", active_module_id]))
		if int(unload_result["code"]) == 0:
			_append_ui_log("Virtual microphone source unloaded.")
		else:
			_append_ui_log("WARNING: Could not unload virtual source module: " + str(unload_result["output"]))
	elif not active_source_name.is_empty():
		_unload_source_by_name(active_source_name)
	if adb_path != "" and not _serial().is_empty():
		var phone_stop_result := _execute_adb(PackedStringArray(["shell", "am", "force-stop", PACKAGE_NAME]))
		if int(phone_stop_result["code"]) == 0:
			_set_phone_mic_status("Phone microphone: Off · Audio Source stopped on Android.", "off")
		else:
			_set_phone_mic_status("Phone microphone: Stop requested; check the phone if its indicator remains visible.", "error")
	active_module_id = ""
	active_source_name = ""
	fifo_path = ""
	forward_port = -1
	last_bridge_status = ""
	_set_status("Stopped", false)
	if not reason.is_empty():
		_append_ui_log(reason)
	_refresh_button_states()

func _on_stop_pressed() -> void:
	if not stream_active:
		return
	_append_ui_log("Stop requested; closing the bridge, ADB forward, and virtual source…")
	_finish_stream("Virtual microphone stopped and cleaned up.")

func _apply_source_volume() -> void:
	if volume_slider == null or pactl_path.is_empty() or active_source_name.is_empty() or active_module_id.is_empty():
		return
	var volume_text := "%d%%" % int(round(volume_slider.value))
	var result := _execute_program(pactl_path, PackedStringArray(["set-source-volume", active_source_name, volume_text]))
	if int(result["code"]) != 0:
		_append_ui_log("WARNING: Could not set virtual microphone volume to %s: %s" % [volume_text, str(result["output"])])

func _on_volume_changed(value: float) -> void:
	volume_value_label.text = "%d%%" % int(round(value))
	if not volume_dragging:
		_apply_source_volume()
	_save_settings()

func _on_volume_drag_started() -> void:
	volume_dragging = true

func _set_volume_preset(preset_value: float) -> void:
	volume_dragging = false
	volume_slider.value = preset_value
	_apply_source_volume()
	_append_ui_log("Virtual microphone source volume set to %d%%." % int(preset_value))

func _on_volume_drag_ended(value_changed: bool) -> void:
	volume_dragging = false
	if value_changed:
		_apply_source_volume()
		_append_ui_log("Virtual microphone source volume set to %d%%." % int(round(volume_slider.value)))

func _on_github_pressed() -> void:
	var error := OS.shell_open(GITHUB_URL)
	if error != OK:
		_append_ui_log("Could not open the GitHub page automatically: " + GITHUB_URL)

func _on_open_log_folder_pressed() -> void:
	var log_dir := ProjectSettings.globalize_path("user://")
	var error := OS.shell_open("file://" + log_dir)
	if error != OK:
		_append_ui_log("Could not open the log directory: " + log_dir)

func _on_clear_log_pressed() -> void:
	log_view.clear()
	var file := FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file != null:
		file.close()

func _refresh_button_states() -> void:
	var start_button := find_child("StartButton", true, false) as Button
	if start_button != null:
		start_button.disabled = stream_active or not requirements_ok
	if serial_edit != null:
		serial_edit.editable = not stream_active
	if source_name_edit != null:
		source_name_edit.editable = not stream_active
	if detect_button_ref != null:
		detect_button_ref.disabled = stream_active
	var stop_button := find_child("StopButton", true, false) as Button
	if stop_button != null:
		stop_button.disabled = not stream_active

func _set_phone_mic_status(message: String, state: String = "off") -> void:
	if phone_mic_label == null:
		return
	phone_mic_label.text = message
	var status_color := C_MUTED
	if state == "active":
		status_color = C_TEAL
	elif state == "starting":
		status_color = C_AMBER
	elif state == "error":
		status_color = C_RED
	phone_mic_label.add_theme_color_override("font_color", status_color)

func _set_status(text_value: String, positive: bool) -> void:
	if status_label == null:
		return
	status_label.text = text_value.to_upper()
	var dot_color := C_TEAL if positive else C_AMBER
	if text_value.to_lower().contains("fail") or text_value.to_lower().contains("unavailable") or text_value.to_lower().contains("missing"):
		dot_color = C_RED
	status_dot.add_theme_color_override("font_color", dot_color)
	var bg := Color("#172d35") if positive else Color("#30291e")
	var border := Color("#2b5c5d") if positive else Color("#5b4930")
	if dot_color == C_RED:
		bg = Color("#331f2b")
		border = Color("#6a3545")
	status_pill.add_theme_stylebox_override("panel", _flat_style(bg, border, 18, 1))

func _append_ui_log(text_value: String) -> void:
	if text_value.is_empty():
		return
	if log_view != null:
		if not log_view.text.is_empty():
			log_view.append_text("\n")
		log_view.append_text(text_value)
	var file_mode := FileAccess.READ_WRITE if FileAccess.file_exists(LOG_PATH) else FileAccess.WRITE
	var file := FileAccess.open(LOG_PATH, file_mode)
	if file != null:
		file.seek_end()
		file.store_line(text_value)
		file.close()

func _on_close_requested() -> void:
	_save_settings()
	if stream_active:
		_finish_stream("Application closed; audio stream stopped.")
	get_tree().quit()
