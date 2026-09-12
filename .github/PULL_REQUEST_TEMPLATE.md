## What & why

<!-- What does this change, and why? -->

## Security checklist

- [ ] Does this touch anything that builds a URL/command from user- or
      bridge-supplied input (`hue.py`'s `api`, `set_room`, `set_light`,
      `pair`, `bridge_config`, `valid_id`, `valid_ip`)? If yes, explain what
      input can reach it and why it's still safe.
- [ ] No new third-party Python dependency (stdlib only).
- [ ] No `Image`/resource loaded from a remote or bridge-supplied URL in QML.
- [ ] `python3 -m py_compile hue.py` passes locally.

## Testing

<!-- How did you verify this? Screenshots welcome for UI changes. -->
