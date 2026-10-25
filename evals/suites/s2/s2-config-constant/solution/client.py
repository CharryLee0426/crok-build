import settings


def fetch(url, timeout=settings.DEFAULT_TIMEOUT):
    return {"url": url, "timeout": timeout}
