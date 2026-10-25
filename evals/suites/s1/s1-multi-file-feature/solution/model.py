from dataclasses import dataclass


@dataclass
class Task:
    title: str
    done: bool = False
    priority: int = 0
