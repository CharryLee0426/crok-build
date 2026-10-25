from src.legacy.compat import money


def cart_total(items):
    return money(sum(item["price"] * item["qty"] for item in items))
