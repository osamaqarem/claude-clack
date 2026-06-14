# How to use

## Requirements

- **macOS:** `afplay`, ships with MacOS.
- **Linux:** `aplay`, ships with several distros.

## Install

1. **Make the hook executable:**

   ```sh
   chmod +x /ABSOLUTE/PATH/TO/claude-clack/clack.sh
   ```

2. **Find the absolute path** to `clack.sh` (you'll paste it into settings):

   ```sh
   echo "$PWD/clack.sh"   # run from inside the claude-clack directory
   ```

3. **Add the hook to your Claude Code settings.** Open `~/.claude/settings.json`. Add `PostToolUse` and `Notification`
   hooks, replacing the path with the one from step 2:

   ```json
   {
     "hooks": {
       "PostToolUse": [
         {
           "matcher": "Edit|Write|MultiEdit|NotebookEdit",
           "hooks": [
             {
               "type": "command",
               "command": "/ABSOLUTE/PATH/TO/claude-clack/clack.sh",
               "async": true
             }
           ]
         }
       ],
       "Notification": [
         {
           "matcher": "permission_prompt",
           "hooks": [
             {
               "type": "command",
               "command": "/ABSOLUTE/PATH/TO/claude-clack/clack.sh",
               "async": true
             }
           ]
         }
       ]
     }
   }
   ```

   If you already have a `hooks` block, add just the `PostToolUse` entry to it
   rather than replacing the whole object.

4. **Restart Claude Code**, or start a new session.

Then make an edit and you should hear it.

## Tuning

All tuning lives in **`settings.json` in this folder** (next to `clack.sh`). Edit that file to change anything; changes take
effect on the next edit, no restart needed.

> This is claude-clack's own `settings.json`, separate from Claude Code's
> `~/.claude/settings.json` where you registered the hook above.

```json
{
  "volume": 0.5,
  "disable": false,
  "chars_per_clack": 12,
  "min": 3,
  "max": 30,
  "gap_min_ms": 45,
  "gap_max_ms": 110,
  "prompt_sound": true
}
```

| Key               | Default  | Effect                                                                                       |
| ----------------- | -------- | -------------------------------------------------------------------------------------------- |
| `volume`          | `0.5`    | Playback volume, `0.0`–`1.0` (macOS/`afplay` only; ignored on Linux/`aplay`).                |
| `disable`         | `false`  | Set to `true` to mute every sound without unwiring the hooks.                                |
| `chars_per_clack` | `12`     | Inserted characters per clack. lower = longer bursts.                                        |
| `min`             | `3`      | Floor on clacks per edit.                                                                    |
| `max`             | `30`     | Cap on clacks per edit                                                                       |
| `gap_min_ms`      | `45`     | Shortest gap between keystrokes, milliseconds.                                               |
| `gap_max_ms`      | `110`    | Longest gap between keystrokes, milliseconds.                                                |
| `count`           | _absent_ | Add this key to pin a fixed clack count, ignoring edit size and the min/max clamp.           |
| `prompt_sound`    | `true`   | Play the quack on a `Notification` (scope it with the matcher in `~/.claude/settings.json`). |
