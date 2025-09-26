extends RefCounted;
class_name WebSocketClient;

signal connected_to_socket;
signal disconnected_from_socket;
signal connection_failure;
signal received_message(message: String);

const TIME_TO_FAILURE = 5;

var _websocket: WebSocketPeer;
var _connection_state: int = 0;
var _curret_connecting_time: float = 0;

func _connect(address: String, tls_options: TLSOptions = null) -> int:
	_curret_connecting_time = 0;
	_websocket = WebSocketPeer.new();
	return _websocket.connect_to_url(address, tls_options);

func _disconnect(reason: String) -> void:
	if _websocket == null || _websocket.get_ready_state() > _websocket.STATE_OPEN:
		return;
	
	_websocket.close(1000, reason);

func _send(text: String) -> int:
	if text.is_empty():
		return ERR_INVALID_DATA;
	
	if _websocket == null:
		return ERR_CONNECTION_ERROR;
	
	if _connection_state != _websocket.STATE_OPEN:
		return ERR_BUSY;
	
	return _websocket.send_text(text);
	
func _resolve_state() -> void:
	var current_state: int = _websocket.get_ready_state();
	
	if current_state == _connection_state:
		return;
		
	_connection_state = current_state;
	
	match _connection_state:
		_websocket.STATE_OPEN:
			connected_to_socket.emit();
		_websocket.STATE_CLOSED:
			_websocket = null;
			disconnected_from_socket.emit();

func _resolve_pending_connection(delta: float) -> void:
	if _connection_state != _websocket.STATE_CONNECTING:
		return;
		
	_curret_connecting_time += delta;
	
	if _curret_connecting_time >= TIME_TO_FAILURE:
		print("Failed connecting to socket :(")
		connection_failure.emit();
		_websocket = null;
		
func _resolve_packets() -> void:
	if _connection_state < _websocket.STATE_OPEN && _connection_state > _websocket.STATE_CLOSING:
		return;
	
	while _websocket.get_available_packet_count() > 0:
		var packet: PackedByteArray = _websocket.get_packet();
		var packet_as_string = packet.get_string_from_utf8();

		if packet_as_string.is_empty() || !_websocket.was_string_packet():
			continue;
			
		received_message.emit(packet_as_string);

func _poll(delta: float) -> void:
	if _websocket == null:
		return;
	
	_websocket.poll();
	_resolve_state();
	_resolve_pending_connection(delta);
	_resolve_packets();
	
