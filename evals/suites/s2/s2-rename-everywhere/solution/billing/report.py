from billing.core import compute_total


def report_line(name, items):
    return f"{name}: {compute_total(items):.2f}"
