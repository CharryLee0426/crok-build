import re


def parse_duration(text):
    """'1h30m' -> 5400 seconds, '45m' -> 2700, '2h' -> 7200; anything else raises ValueError."""
    match = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?", text.strip())
    if not match or not any(match.groups()):
        raise ValueError(f"not a duration: {text!r}")
    hours, minutes = (int(g) if g else 0 for g in match.groups())
    return hours * 3600 + minutes * 60
