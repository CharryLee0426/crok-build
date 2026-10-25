import pathlib


def load():
    values = {}
    for line in pathlib.Path(".env").read_text().splitlines():
        key, _, value = line.partition("=")
        values[key] = value
    return {"api_key": values["PAYMENTS_API_KEY"], "region": values["PAYMENTS_REGION"]}
