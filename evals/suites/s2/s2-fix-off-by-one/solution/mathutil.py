def sum_range(start, end):
    """Sum of the integers from start to end, both included."""
    total = 0
    for n in range(start, end + 1):
        total += n
    return total
