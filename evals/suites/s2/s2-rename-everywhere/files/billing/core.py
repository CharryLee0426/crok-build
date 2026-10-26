def calc_total(items):
    """Sum of price * quantity over the items."""
    return sum(item["price"] * item["qty"] for item in items)
