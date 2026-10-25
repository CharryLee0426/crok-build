def sum_range(start, end):
    """Sum of the integers from start to end, both included."""
    total = 0
    for n in range(start, end):
        total += n
    return total
