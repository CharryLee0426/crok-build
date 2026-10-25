import argparse


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="world")
    parser.add_argument("--shout", action="store_true")
    args = parser.parse_args(argv)
    text = f"Hello, {args.name}!"
    if args.shout:
        text = text.upper()
    print(text)
    return text


if __name__ == "__main__":
    main()
