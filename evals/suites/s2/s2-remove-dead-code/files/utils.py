LEGACY_PREFIX = "v1:"


def normalize(name):
    return name.strip().lower()


def legacy_helper(name):
    return LEGACY_PREFIX + normalize(name)
