extends AwaitableHTTPRequest


class RMSCalculator:
	# --------------------------
	# Tunables
	# --------------------------
	var window_size: int = 1000          # RMS window length, in samples
	var shift_size: int = 1000           # hop size (how often to compute RMS), in samples
	var threshold: float = 1.75         # trigger threshold on RMS
	var sample_rate: float = 3960.0     # samples per second
	var threshold_count: int = 15  # How many consecutive values need to pass before we tap


	# How much history to keep (seconds) for memory trimming.
	# Keep enough for at least one full window plus extra context.
	var retention_seconds: float = 10.0

	# --------------------------
	# Internal State
	# --------------------------
	var curr_time_idx: float = -INF      # "now" in absolute seconds (wall-time you advance via should_tap)
	var raw_data: Array = []             # appended raw samples (floats)
	var _raw_start_time: float = 0.0     # absolute time of raw_data[0] in seconds
	var _next_rms_start_idx: int = 0     # next raw index to start an RMS window from

	# Cumulative prefix of squares to enable O(1) window sums:
	# _sq_prefix[i] = sum_{k=0..i-1}(raw_data[k]^2). Length = raw_data.size()+1, with _sq_prefix[0] = 0.
	var _sq_prefix: Array = [0.0]

	# Computed RMS points as Array of Dictionaries: { "t": float, "v": float }
	# t is absolute seconds (center of the window), v is RMS value.
	var computed_rms: Array = []


	# --------------------------
	# Helpers
	# --------------------------

	func _append_raw_samples(samples: Array) -> void:
		# Extend raw_data and square prefix in one pass
		for x in samples:
			raw_data.append(x)
			_sq_prefix.append(_sq_prefix[_sq_prefix.size() - 1] + float(x) * float(x))


	func _maybe_init_time(start_time: float) -> void:
		if curr_time_idx == -INF:
			curr_time_idx = start_time
		if raw_data.size() == 0 and _sq_prefix.size() == 1:
			_raw_start_time = start_time


	func _compute_new_rms() -> void:
		# Compute as many RMS points as possible from _next_rms_start_idx,
		# using hop size = shift_size, as long as a full window fits.
		var n: int = raw_data.size()
		if window_size <= 0 or n < window_size:
			return
		
		# Max starting index inclusive so that [i, i+window_size) fits
		var last_start: int = n - window_size
		
		# Ensure the next start is aligned to our hop grid.
		# (If user changes shift_size mid-stream, we still progress forward cleanly.)
		_next_rms_start_idx = clamp(_next_rms_start_idx, 0, max(0, last_start))
		
		while _next_rms_start_idx <= last_start:
			# Window sum of squares via prefix sums
			var a: int = _next_rms_start_idx
			var b: int = a + window_size
			var sum_sq: float = _sq_prefix[b] - _sq_prefix[a]
			var rms: float = sqrt(sum_sq / float(window_size))
			
			# Time stamp at the center of the window
			var center_sample: float = a + (window_size * 0.5)
			var t_center: float = _raw_start_time + center_sample / sample_rate
			
			computed_rms.append({ "t": t_center, "v": rms })
			
			_next_rms_start_idx += shift_size


	func _prune_old_data() -> void:
		# Drop raw samples that are too old to matter for future windows
		# Keep at least one full window before the current sample position.
		# Compute the sample index corresponding to (curr_time_idx - retention_seconds)
		var oldest_keep_time: float = curr_time_idx - retention_seconds
		var oldest_keep_sample_idx: int = int(floor((oldest_keep_time - _raw_start_time) * sample_rate)) - window_size
		oldest_keep_sample_idx = max(0, oldest_keep_sample_idx)
		
		if oldest_keep_sample_idx <= 0:
			return
		
		# Limit to available data
		oldest_keep_sample_idx = min(oldest_keep_sample_idx, raw_data.size())
		if oldest_keep_sample_idx == 0:
			return
		
		# Slice raw_data and rebuild prefix from zero for correctness/simplicity
		raw_data = raw_data.slice(oldest_keep_sample_idx, raw_data.size() - oldest_keep_sample_idx)
		
		# Rebuild prefix
		_sq_prefix.clear()
		_sq_prefix.append(0.0)
		for x in raw_data:
			_sq_prefix.append(_sq_prefix[_sq_prefix.size() - 1] + float(x) * float(x))
		
		# Bump raw start time forward by the number of dropped samples
		_raw_start_time += float(oldest_keep_sample_idx) / sample_rate
		
		# Adjust next RMS start index to reflect dropped samples
		_next_rms_start_idx = max(0, _next_rms_start_idx - oldest_keep_sample_idx)
		
		# Prune computed RMS points older than retention window (strictly older than oldest_keep_time)
		var kept: Array = []
		for p in computed_rms:
			if p["t"] >= oldest_keep_time:
				kept.append(p)
		computed_rms = kept


	func _latest_rms_values(time_s: float, count: int) -> Array:
		# Return up to `count` latest RMS points with t <= time_s
		var vals: Array = []
		var i := computed_rms.size() - 1
		while i >= 0 and vals.size() < count:
			var p: Dictionary = computed_rms[i]
			if p["t"] <= time_s:
				vals.append(p)
			i -= 1
		return vals
		


	# --------------------------
	# Public API
	# --------------------------

	# Update the raw data points, and compute the new RMS values starting
	# from where we last left off.
	func add_raw_data(numbers: Array, start_time: float) -> void:
		_maybe_init_time(start_time)
		_append_raw_samples(numbers)
		_compute_new_rms()
		# Optionally prune immediately after a big append (keeps memory bounded)
		_prune_old_data()


	# Given the delta of the frames, do the following:
	# 1. Advance "now" by delta (curr_time_idx)
	# 2. Trim old raw/RMS points to save memory
	# 3. Ensure RMS is up-to-date for any data already buffered
	# 4. Return true if the most recent in-time RMS crosses threshold
	func should_tap(delta: float) -> bool:
		if curr_time_idx == -INF:
			# No timing context yet; nothing to decide.
			return false
		
		curr_time_idx += max(0.0, delta)
		
		# We may have enough raw data buffered to compute more RMS now
		_compute_new_rms()
		
		# Trim old data
		_prune_old_data()
				
		# Decide: check the latest N RMS values at or before "now"
		var p_list: Array = _latest_rms_values(curr_time_idx, self.threshold_count)
		var pass_count := 0
		for p in p_list:
			if p.has("v") and float(p["v"]) >= self.threshold:
				pass_count += 1

		if pass_count >= self.threshold_count:
			print("clicked")
			return true
		return false


	# Optional convenience: call this if you change window/shift at runtime to reset computed state cleanly.
	func reset_rms_progress() -> void:
		_next_rms_start_idx = 0
		computed_rms.clear()
		_sq_prefix.clear()
		_sq_prefix.append(0.0)
		# Keep raw_data and times; just recompute RMS from scratch on next add/should_tap
		
var peer = WebSocketClient.new()
var rmsInstance = RMSCalculator.new()

func _parse_connected_devices(resp: HTTPResult) -> Array:
	if !resp.success() or resp.status_err():
		push_error("Couldn't get connected devices")
		
	var body = resp.body_as_json() as Dictionary
	var all_devices = []
	
	var list = body.get("data").get("devices")
	
	for item in list:
		var typedItem = item as Dictionary
		all_devices.append(typedItem.get("address"))
	
	return all_devices
	
func get_first_chnl_data(json_msg: Dictionary):
	return json_msg.get("data")[0]
	 
var msg_printed = false
func handle_ws_message(message):
	message = JSON.parse_string(message) 
	var data = get_first_chnl_data(message)
	var starting_time_stamp = message.get("timestamp")
	rmsInstance.add_raw_data(data, starting_time_stamp)
	
func print_sad():
	print("Failed connection")

func print_happy():
	print("Connected")

func _ready() -> void:
	var get_devices = await self.async_request("http://127.0.0.1:64209/connections/get_connected_devices")
	var addressses = _parse_connected_devices(get_devices)
	var first_address = addressses[0]
	print("Connecting to: " + first_address)
	peer.received_message.connect(handle_ws_message)
	peer.connection_failure.connect(print_sad)
	peer.connected_to_socket.connect(print_happy)
	peer._connect("ws://127.0.0.1:64209/ws/" + first_address + "?dtype=emg&app_id=dinogame")

func gen_press():
	var ui_accept = InputEventAction.new()
	ui_accept.action = "ui_accept"
	ui_accept.pressed = true
	Input.parse_input_event(ui_accept)

func gen_release():
	var ui_accept = InputEventAction.new()
	ui_accept.action = "ui_accept"
	ui_accept.pressed = false
	Input.parse_input_event(ui_accept)

func _process(delta: float) -> void:
	gen_release()
	peer._poll(delta)
	if rmsInstance.should_tap(delta):
		gen_press()

	
	
	
	
	
	
	
	
