from billing.core import calc_total


def report_line(name, items):
    return f"{name}: {calc_total(items):.2f}"
