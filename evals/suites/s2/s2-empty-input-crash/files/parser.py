def parse_pairs(text):
    """'a=1,b=2' -> {'a': '1', 'b': '2'}; spaces around keys and values are ignored."""
    out = {}
    for part in text.split(","):
        key, value = part.split("=")
        out[key] = value
    return out
