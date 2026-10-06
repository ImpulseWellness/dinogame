# Play desktop Dino

Dino consumes two virtual controller buttons from the desktop middleware. The game contains no EMG filtering or calibration calculations.

## Play with a sensor

1. Start the desktop backend with the native biosignal-controller library configured.
2. Connect one four-channel sensor through the desktop host.
3. Launch Godot 4.5 with this project.

```powershell
& $env:GODOT_PATH --path . --log-file .godot/game.log
```

4. Select **Calibration & tuning** in the game. The host page opens at `http://127.0.0.1:64209/controller/tuning`.
5. Complete rest and contraction calibration. If saved settings exist, select the explicit reuse option instead.
6. Return to Dino and select **Resume**.

Channel zero drives jump. Channel one drives duck. Continue holding jump after takeoff to increase height. Duck blocks a jump until released. Holding jump through landing never repeats it. A jump press made in the air cannot jump after landing.

Input loss pauses the game. Reconnection updates the controller while the game remains paused. Select **Resume** to apply the current held controls. Press Escape to pause or request resume. Use **Quit** to leave the game.

For another backend address, set `DINO_CONTROLLER_URL` or pass `--controller-url` after `--`.

```powershell
& $env:GODOT_PATH --path . --log-file .godot/game.log -- --controller-url=http://127.0.0.1:64209
```

## Play with the keyboard

Use the explicit keyboard mode for gameplay testing without a sensor.

```powershell
& $env:GODOT_PATH --path . --log-file .godot/keyboard.log -- --keyboard
```

Select **Resume**. Space holds jump. Down holds duck. Escape pauses or resumes. The keyboard uses the same gameplay button rules. Sensor mode never falls back to keyboard controls.

To tune the maximum extra jump hold duration, pass `--jump-hold-seconds`. The allowed range is zero through 0.5 seconds. The initial value is 0.22 seconds.

```powershell
& $env:GODOT_PATH --path . --log-file .godot/keyboard.log -- --keyboard --jump-hold-seconds=0.18
```

## Run verification

Set `GODOT_PATH` to the Godot 4.5 executable. Run the script from this project directory.

```powershell
./tests/run.ps1 -GodotPath $env:GODOT_PATH
```

The gameplay test instantiates the actual main scene and sends keyboard events through Godot. It checks jump height, priority, between-frame taps, ignored airborne presses, landing behavior, pause, held resume, and elapsed-time movement.

The transport test connects the actual game to a local Godot WebSocket server on port 19701. It checks loss before motion, paused polling, manual resynchronization, short taps, session races, acknowledgement of obsolete responses, and malformed input. Successful output ends with `DINO_GAMEPLAY_RESULT` and `DINO_TRANSPORT_RESULT`, each with an empty failures array.

These checks verify deterministic behavior. They do not prove physical sensor responsiveness or sustained rendering performance on a phone.

## Observe the real backend

Create a JSON plan for manual game actions. Keep the step times in ascending order.

```json
{
	"durationSeconds": 8,
	"steps": [
		{"atSeconds": 1, "action": "resume"},
		{"atSeconds": 4, "action": "resume"}
	]
}
```

Run the headless observer against the real backend. Drive the sensor or replay source through the host during the run.

```powershell
& $env:GODOT_PATH --headless --path . --log-file .godot/probe.log --script tests/controller_probe.gd -- --controller-url=http://127.0.0.1:64209 --probe-plan=C:/path/to/plan.json
```

The observer disables obstacles and prints `DINO_PROBE_READY`, scheduled actions, and `DINO_PROBE` snapshots every 50 milliseconds. Snapshots expose game position, jump count, held controls, pause status, accepted controller state, transport acknowledgement, and frame-request latency. Supported actions are `resume`, `pause`, and `retry`.

`controller-layout.json` declares Dino's required input IDs. `data_process/controller_client.gd` accepts only the version 1 Dino controller contract. The adapter polls even while paused, allows one frame request in flight, and accepts retained transitions before gameplay moves. Manual resume requests a state-only frame and discards paused history.

Rendering and physics are capped at 60. Horizontal movement advances 960 pixels per active gameplay second. Jump height uses active simulation time. The jump hold default remains available for desktop tuning.
