import argparse


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="world")
    args = parser.parse_args(argv)
    text = f"Hello, {args.name}!"
    print(text)
    return text


if __name__ == "__main__":
    main()
