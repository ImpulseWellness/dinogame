extends Node

signal availability_changed(available: bool, reason: String)

const REQUIRED_INPUTS: Array[String] = ["button_1", "button_2"]
const MIN_FRAME_INTERVAL_US: int = 16667
const TRANSPORT_TIMEOUT_US: int = 1000000

var base_url: String = "http://127.0.0.1:64209"
var available: bool = false
var reason: String = "connecting"
var has_current_frame: bool = false
var state: Dictionary = {"button_1": {"pressed": false, "value": 0}, "button_2": {"pressed": false, "value": 0}}
var session_id: String = ""
var transition_sequence: int = 0
var frame_sequence: int = -1
var frames_received: int = 0
var requests_sent: int = 0
var last_request_latency_us: int = 0
var max_request_latency_us: int = 0
var calibration: Dictionary = {}

var _socket: WebSocketPeer
var _descriptor_valid: bool = false
var _frames: Array[Dictionary] = []
var _inflight: bool = false
var _request_sent_at_us: int = 0
var _last_request_at_us: int = -MIN_FRAME_INTERVAL_US
var _retry_at_us: int = 0
var _connect_started_at_us: int = 0
var _force_resynchronize: bool = false
var _availability_at_us: int = -1
var _expected_session: String = ""
var _ack_session: String = ""
var _ack_transition_sequence: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not OS.get_environment("DINO_CONTROLLER_URL").is_empty():
		base_url = OS.get_environment("DINO_CONTROLLER_URL")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--controller-url="):
			base_url = argument.trim_prefix("--controller-url=")
	base_url = base_url.trim_suffix("/")
	_connect_socket()

func _connect_socket() -> void:
	_socket = WebSocketPeer.new()
	_descriptor_valid = false
	_inflight = false
	_availability_at_us = -1
	_ack_session = ""
	_ack_transition_sequence = 0
	_force_resynchronize = true
	_connect_started_at_us = Time.get_ticks_usec()
	var url: String = base_url.replace("https://", "wss://").replace("http://", "ws://") + "/controller/ws"
	if _socket.connect_to_url(url) != OK:
		_transport_lost("connection_failed")

func _process(_delta: float) -> void:
	poll_socket()

func poll_socket() -> void:
	var now_us: int = Time.get_ticks_usec()
	if _socket == null:
		if now_us >= _retry_at_us:
			_connect_socket()
		return
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			while _socket.get_available_packet_count() > 0:
				var packet: PackedByteArray = _socket.get_packet()
				if not _socket.was_string_packet():
					_protocol_error()
					return
				var message = JSON.parse_string(packet.get_string_from_utf8())
				if not message is Dictionary or not _receive_message(message):
					_protocol_error()
					return
			if _inflight and now_us - _request_sent_at_us > TRANSPORT_TIMEOUT_US:
				_transport_lost("controller_timeout")
		WebSocketPeer.STATE_CONNECTING:
			if now_us - _connect_started_at_us > TRANSPORT_TIMEOUT_US:
				_transport_lost("connection_timeout")
		WebSocketPeer.STATE_CLOSED:
			_transport_lost("controller_disconnected")

func _transport_lost(loss_reason: String) -> void:
	if _socket != null:
		_socket.close()
	_socket = null
	_descriptor_valid = false
	_inflight = false
	_retry_at_us = Time.get_ticks_usec() + 1000000
	_frames.clear()
	has_current_frame = false
	_set_available(false, loss_reason)

func _protocol_error() -> void:
	_transport_lost("invalid_controller_message")

func _set_available(next_available: bool, next_reason: String) -> void:
	var changed: bool = available != next_available or reason != next_reason
	available = next_available
	reason = next_reason
	if not available:
		_frames.clear()
		has_current_frame = false
	if changed:
		availability_changed.emit(available, reason)

func _valid_identity(message: Dictionary) -> bool:
	return message.get("schemaVersion") == 1 and message.get("controllerId") == "player_1" and message.get("layoutId") == "dino"

func _receive_message(message: Dictionary) -> bool:
	if not _valid_identity(message):
		return false
	match message.get("type"):
		"description":
			if not message.get("inputs") is Array:
				return false
			var found: Array = []
			for input in message["inputs"]:
				if not input is Dictionary:
					return false
				if input.get("inputId") in REQUIRED_INPUTS and input.get("type") == "button" and input.get("enabled") == true:
					found.append(input["inputId"])
			_descriptor_valid = found.size() == 2 and found.has("button_1") and found.has("button_2")
			return _descriptor_valid
		"availability":
			if not _descriptor_valid or not message.get("sessionId") is String or not message.get("available") is bool or not _valid_integer(message.get("observedAtUs")) or not message.get("reason") is String:
				return false
			if message.has("calibration") and not message["calibration"] is Dictionary:
				return false
			var observed_at: int = int(message["observedAtUs"])
			if observed_at < _availability_at_us:
				return true
			_availability_at_us = observed_at
			var next_session: String = message["sessionId"]
			if next_session != _expected_session:
				_frames.clear()
				has_current_frame = false
				_set_available(false, "controller_session_changed")
			_expected_session = next_session
			calibration = message.get("calibration", {})
			_set_available(message["available"], message["reason"])
			return true
		"frame":
			return _accept_frame(message)
	return false

func _valid_integer(value) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value)) and float(value) >= 0

func _accept_frame(message: Dictionary) -> bool:
	if not _inflight or not _descriptor_valid:
		return false
	_inflight = false
	last_request_latency_us = Time.get_ticks_usec() - _request_sent_at_us
	max_request_latency_us = maxi(max_request_latency_us, last_request_latency_us)
	for field: String in ["sequence", "observedAtUs", "transitionSequence"]:
		if not _valid_integer(message.get(field)):
			return false
	if not message.get("sessionId") is String or not message.get("available") is bool or not message.get("resynchronize") is bool or not message.get("reason") is String or not message.get("state") is Dictionary or not message.get("transitions") is Array:
		return false
	for input_id: String in REQUIRED_INPUTS:
		var input = message["state"].get(input_id)
		if not input is Dictionary or not input.get("pressed") is bool or input.get("value") != int(input["pressed"]):
			return false
	for event in message["transitions"]:
		if not event is Dictionary or not _valid_integer(event.get("sequence")) or not _valid_integer(event.get("atUs")) or not event.get("pressed") is bool or not event.get("inputId") in REQUIRED_INPUTS:
			return false
	_ack_session = message["sessionId"]
	_ack_transition_sequence = int(message["transitionSequence"])
	if message["sessionId"] != _expected_session or int(message["observedAtUs"]) < _availability_at_us:
		_force_resynchronize = true
		return true
	var changed_session: bool = message["sessionId"] != session_id
	if not changed_session and int(message["sequence"]) <= frame_sequence:
		_force_resynchronize = true
		return true
	if changed_session and not message["resynchronize"]:
		return false
	var cursor: int = 0 if changed_session else transition_sequence
	var last_at: int = -1
	var replay: Dictionary = state.duplicate(true)
	for event in message["transitions"]:
		if not event is Dictionary or not _valid_integer(event.get("sequence")) or not _valid_integer(event.get("atUs")) or not event.get("pressed") is bool or not event.get("inputId") in REQUIRED_INPUTS:
			return false
		if int(event["sequence"]) != cursor + 1 or int(event["atUs"]) < last_at or int(event["atUs"]) > int(message["observedAtUs"]):
			return false
		cursor = int(event["sequence"])
		last_at = int(event["atUs"])
		replay[event["inputId"]] = {"pressed": event["pressed"], "value": int(event["pressed"])}
	if message["resynchronize"]:
		if not message["transitions"].is_empty() or (not changed_session and int(message["transitionSequence"]) < transition_sequence):
			return false
	else:
		if cursor != int(message["transitionSequence"]):
			return false
		for input_id: String in REQUIRED_INPUTS:
			if replay[input_id]["pressed"] != message["state"][input_id]["pressed"]:
				return false
	session_id = message["sessionId"]
	frame_sequence = int(message["sequence"])
	transition_sequence = int(message["transitionSequence"])
	state = message["state"].duplicate(true)
	frames_received += 1
	_set_available(message["available"], message["reason"])
	has_current_frame = available
	if available:
		_frames.append(message)
	return true

func request_frame() -> void:
	var now_us: int = Time.get_ticks_usec()
	if _socket == null or _socket.get_ready_state() != WebSocketPeer.STATE_OPEN or not _descriptor_valid or _inflight or now_us - _last_request_at_us < MIN_FRAME_INTERVAL_US:
		return
	var request: Dictionary = {"type": "frame", "sessionId": _ack_session, "afterTransitionSequence": _ack_transition_sequence, "resynchronize": _force_resynchronize}
	if _socket.send_text(JSON.stringify(request)) != OK:
		_transport_lost("controller_send_failed")
		return
	_force_resynchronize = false
	_inflight = true
	_request_sent_at_us = now_us
	_last_request_at_us = now_us
	requests_sent += 1

func request_resynchronize() -> void:
	_frames.clear()
	_force_resynchronize = true

func take_frames() -> Array[Dictionary]:
	var frames: Array[Dictionary] = _frames
	_frames = []
	return frames

func get_snapshot() -> Dictionary:
	return {"available": available, "reason": reason, "hasCurrentFrame": has_current_frame, "sessionId": session_id, "transitionSequence": transition_sequence, "ackSessionId": _ack_session, "ackTransitionSequence": _ack_transition_sequence, "framesReceived": frames_received, "requestsSent": requests_sent, "inflight": _inflight, "lastRequestLatencyUs": last_request_latency_us, "maxRequestLatencyUs": max_request_latency_us, "state": state.duplicate(true)}
