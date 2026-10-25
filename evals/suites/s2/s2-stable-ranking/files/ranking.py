def rank(players):
    """Players by score, highest first; equal scores keep their input order."""
    players = list(players)
    for i in range(len(players)):
        best = i
        for j in range(i + 1, len(players)):
            if players[j]["score"] >= players[best]["score"]:
                best = j
        players[i], players[best] = players[best], players[i]
    return players
