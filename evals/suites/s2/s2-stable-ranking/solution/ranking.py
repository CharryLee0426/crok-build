def rank(players):
    """Players by score, highest first; equal scores keep their input order."""
    return sorted(players, key=lambda p: -p["score"])
