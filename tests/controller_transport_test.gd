extends SceneTree

var server: TCPServer = TCPServer.new()
var peer: WebSocketPeer
var game: Node
var requests: Array[Dictionary] = []
var failures: Array[String] = []
var checks: int = 0
var session: String = "fixture:1"
var producer_us: int = 1000000
var frame_sequence: int = 0
var cursor: int = 0
var held: Dictionary = {"button_1": {"pressed": false, "value": 0}, "button_2": {"pressed": false, "value": 0}}
var identity: Dictionary = {"schemaVersion": 1, "controllerId": "player_1", "layoutId": "dino"}
var description_sent: bool = false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if server.listen(19701, "127.0.0.1") != OK:
		push_error("Transport test requires free localhost port 19701")
		quit(2)
		return
	process_frame.connect(_poll_server)
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.obstacles_enabled = false
	var request: Dictionary = await _next_request()
	_check(request.get("sessionId") == "" and request.get("afterTransitionSequence") == 0, "First frame starts with empty transport cursor")
	await _ticks(10)
	_check(game.input_adapter.requests_sent == 1 and requests.is_empty(), "A delayed response allows only one frame request in flight while paused")
	_reply(true)
	await _ticks(2)
	_check(game.get_snapshot()["paused"] and game.input_adapter.has_current_frame, "Available controller never starts game automatically")

	held = _state(true, true)
	game.resume_game()
	await _answer_resume()
	_check(game.game_running and game.get_snapshot()["ducking"] and game.get_snapshot()["jumpCount"] == 0, "Resynchronized held controls duck and defer jump on manual resume")
	request = await _next_request()
	cursor += 1
	producer_us += 100
	held = _state(true, false)
	_reply(false, [{"sequence": cursor, "atUs": producer_us, "inputId": "button_2", "pressed": false}])
	await _ticks(2)
	_check(game.get_snapshot()["jumpCount"] == 1 and game.get_snapshot()["velocityY"] < 0.0, "Socket-delivered duck release launches pending jump")
	await _answer_frames(65)
	_check(game.get_snapshot()["grounded"] and game.get_snapshot()["jumpCount"] == 1, "Socket held state does not repeat on landing")

	request = await _next_request()
	cursor += 1
	producer_us += 100
	held = _state(false, false)
	_reply(false, [{"sequence": cursor, "atUs": producer_us, "inputId": "button_1", "pressed": false}])
	await _ticks(2)
	request = await _next_request()
	producer_us += 100
	var tap: Array = [{"sequence": cursor + 1, "atUs": producer_us - 1, "inputId": "button_1", "pressed": true}, {"sequence": cursor + 2, "atUs": producer_us, "inputId": "button_1", "pressed": false}]
	cursor += 2
	_reply(false, tap)
	await _ticks(2)
	_check(game.get_snapshot()["jumpCount"] == 2 and game.get_snapshot()["velocityY"] < 0.0, "Both socket transitions survive a between-frame short tap")
	await _answer_frames(55)

	request = await _next_request()
	var before_loss_x: float = game.get_snapshot()["x"]
	var old_observed: int = producer_us
	producer_us += 100
	_availability(false, "stale")
	_reply(false, [], true, old_observed)
	await _ticks(2)
	_check(game.get_snapshot()["paused"] and game.get_snapshot()["x"] == before_loss_x, "Availability pauses before motion even with older frame in flight")
	request = await _next_request()
	_check(request.get("sessionId") == session and request.get("afterTransitionSequence") == cursor and request.get("resynchronize"), "Discarded stale-time frame is acknowledged before forced resynchronization")
	_reply(true, [], false)
	await _ticks(2)
	producer_us += 100
	_availability(true, "available")
	held = _state(true, false)
	request = await _next_request()
	_reply(true)
	await _ticks(2)
	_check(game.get_snapshot()["paused"] and game.input_adapter.available and game.input_adapter.has_current_frame, "Reconnection updates held state while game remains paused")
	game.resume_game()
	await _answer_resume()
	_check(game.game_running and game.get_snapshot()["jumpCount"] == 3, "Manual reconnect resume applies current contraction")

	request = await _next_request()
	var old_session: String = session
	session = "fixture:2"
	producer_us += 100
	_availability(true, "available")
	_send({"type": "frame", "sessionId": old_session, "sequence": frame_sequence + 1, "observedAtUs": producer_us - 1, "available": true, "reason": "available", "resynchronize": true, "transitionSequence": 99, "state": _state(false, false), "transitions": []})
	await _ticks(2)
	_check(game.get_snapshot()["paused"] and game.input_adapter.session_id == old_session, "New-session availability rejects old in-flight gameplay state")
	request = await _next_request()
	_check(request.get("sessionId") == old_session and request.get("afterTransitionSequence") == 99 and request.get("resynchronize"), "Rejected old-session frame retains its transport acknowledgement")
	cursor = 0
	frame_sequence = 0
	held = _state(false, true)
	_reply(true)
	await _ticks(2)
	_check(game.get_snapshot()["paused"] and game.input_adapter.session_id == session and game.input_adapter.state["button_2"]["pressed"], "New session synchronizes controls without resuming")

	request = await _next_request()
	_send({"type": "frame", "sessionId": session, "sequence": frame_sequence + 1, "observedAtUs": producer_us + 1, "available": true, "reason": "available", "resynchronize": false, "transitionSequence": 1, "state": _state(true, true), "transitions": [{"sequence": 1, "atUs": producer_us, "inputId": "button_1", "pressed": "true"}]})
	await _ticks(2)
	_check(game.get_snapshot()["paused"] and not game.input_adapter.available and game.input_adapter.reason == "invalid_controller_message", "Malformed button input pauses instead of reaching gameplay")
	print("DINO_TRANSPORT_RESULT " + JSON.stringify({"checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)

func _poll_server() -> void:
	if peer == null and server.is_connection_available():
		peer = WebSocketPeer.new()
		peer.accept_stream(server.take_connection())
	if peer == null:
		return
	peer.poll()
	if peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	if not description_sent:
		description_sent = true
		_send({"type": "description", "inputs": [{"inputId": "button_1", "type": "button", "enabled": true}, {"inputId": "button_2", "type": "button", "enabled": true}]})
		_availability(true, "available")
	while peer.get_available_packet_count() > 0:
		var message = JSON.parse_string(peer.get_packet().get_string_from_utf8())
		if message is Dictionary:
			requests.append(message)

func _send(payload: Dictionary) -> void:
	var message: Dictionary = identity.duplicate()
	message.merge(payload, true)
	peer.send_text(JSON.stringify(message))

func _availability(available: bool, reason: String) -> void:
	_send({"type": "availability", "sessionId": session, "observedAtUs": producer_us, "available": available, "reason": reason, "calibration": {"phase": "ready", "savedAvailable": true}})

func _reply(resynchronize: bool, transitions: Array = [], available: bool = true, observed: int = -1) -> void:
	frame_sequence += 1
	_send({"type": "frame", "sessionId": session, "sequence": frame_sequence, "observedAtUs": producer_us if observed < 0 else observed, "available": available, "reason": "available" if available else "stale", "resynchronize": resynchronize, "transitionSequence": cursor, "state": held, "transitions": transitions})

func _next_request() -> Dictionary:
	var deadline: int = Time.get_ticks_usec() + 3000000
	while requests.is_empty():
		await process_frame
		if Time.get_ticks_usec() > deadline:
			_check(false, "Controller sends a frame request before the test deadline", game.get_snapshot())
			quit(1)
			return {}
	return requests.pop_front()

func _answer_resume() -> void:
	for attempt in range(4):
		var request: Dictionary = await _next_request()
		var desired_state: Dictionary = held
		if not request.get("resynchronize", false):
			held = game.input_adapter.state.duplicate(true)
		_reply(request.get("resynchronize", false))
		held = desired_state
		await _ticks(2)
		if game.game_running:
			return
	_check(false, "Manual resume waits for and accepts a state-only frame")

func _answer_frames(count: int) -> void:
	for frame in range(count):
		var request: Dictionary = await _next_request()
		_reply(request.get("resynchronize", false))
		await _ticks(1)

func _ticks(count: int) -> void:
	for frame in range(count):
		await physics_frame
		await process_frame

func _state(jump: bool, duck: bool) -> Dictionary:
	return {"button_1": {"pressed": jump, "value": int(jump)}, "button_2": {"pressed": duck, "value": int(duck)}}

func _check(passed: bool, message: String, detail: Dictionary = {}) -> void:
	checks += 1
	print(("PASS " if passed else "FAIL ") + message + (" " + JSON.stringify(detail) if not detail.is_empty() else ""))
	if not passed:
		failures.append(message)
