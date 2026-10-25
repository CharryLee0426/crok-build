from src.legacy.compat import money


def cart_total(items):
    return money(sum(item["price"] for item in items))
