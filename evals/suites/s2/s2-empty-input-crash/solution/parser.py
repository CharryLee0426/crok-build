def parse_pairs(text):
    """'a=1,b=2' -> {'a': '1', 'b': '2'}; spaces around keys and values are ignored."""
    out = {}
    for part in text.split(","):
        if not part.strip():
            continue
        key, value = part.split("=", 1)
        out[key.strip()] = value.strip()
    return out
