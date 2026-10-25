def _append_line(path, text):
    with open(path, "a") as f:
        f.write(text + "\n")


def record_order(order):
    _append_line("orders.csv", f"{order['id']},{order['total']}")
