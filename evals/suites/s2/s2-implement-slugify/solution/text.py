import re


def slugify(title):
    """Lower-case, ASCII letters and digits only, words joined by single hyphens.

    'Hello, World!' -> 'hello-world'; '  Crok  2.1 release ' -> 'crok-2-1-release'.
    """
    return "-".join(re.findall(r"[a-z0-9]+", title.lower()))
