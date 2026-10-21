# Markdown showcase

A reply that uses **every** feature the clients render (relay/DESIGN.md §5 "Replies in Markdown"). Demo data and previews on the web, iOS and Android show it verbatim, so one look tells whether a client renders it all.

## Text

Plain text with **bold**, *italic*, ***both***, ~~struck~~, `inline code` and a [link](https://github.com).
A bare URL: https://crok-relay.vercel.app/sessions and a path that must not open: [main.rs](src/main.rs).
This line follows a single newline, so it starts a new line.
A very long word: Pneumonoultramicroscopicsilicovolcanoconiosis_and_a_very_long_identifier_name_that_never_ends_at_all.

### Lists

1. First step
2. Second step, with a nested list:
   - nested bullet
   - another one with `code`
     1. three levels deep
3. Third step

- [x] Write the parser
- [ ] Ship it

> A quote with **bold** text.
>
> > And a nested quote.

---

## Code

```swift
// Swift: keywords, types, strings, numbers
struct Point: Equatable {
    let x: Double, y: Double
    func distance(to other: Point) -> Double {
        let dx = x - other.x, dy = y - other.y
        return (dx * dx + dy * dy).squareRoot() // "Pythagoras"
    }
}
```

```kotlin
fun greet(name: String?): String = "Hello, ${name ?: "world"}!" // nullable
```

```rust
fn main() {
    let words: Vec<&str> = "a b c".split(' ').collect();
    println!("{} words, first = {:?}", words.len(), words.first());
}
```

```python
@dataclass
class User:
    name: str
    age: int = 0  # default

def adults(users: list[User]) -> list[User]:
    return [u for u in users if u.age >= 18 and u.name is not None]
```

```ts
export async function fetchJson<T>(url: string): Promise<T> {
  const res = await fetch(url, { headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return (await res.json()) as T;
}
```

```bash
#!/usr/bin/env bash
for f in *.log; do echo "$f: $(wc -l < "$f") lines"; done # count lines
```

```json
{ "name": "crok", "version": "1.5.3", "private": true, "tags": ["cli", "agent"], "port": 3210, "debug": null }
```

```diff
@@ -1,3 +1,3 @@
 unchanged line
-removed line
+added line
```

```
No language: plain monospace. A very wide line follows, it must scroll sideways inside the bubble and never stretch it: 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789
```

## Tables

| Language | Typing | First release | Notes |
|:---------|:------:|--------------:|-------|
| Rust | static | 2015 | `cargo build` |
| Python | dynamic | 1991 | line one<br>line two |
| Swift | static | 2014 | $O(n \log n)$ sort |

| Column 1 | Column 2 | Column 3 | Column 4 | Column 5 | Column 6 | Column 7 | Column 8 | Column 9 | Column 10 |
|---|---|---|---|---|---|---|---|---|---|
| a wide table | that must | scroll | sideways | inside | the bubble | and never | push it | wider than | the screen |
| This cell has a long sentence that should wrap at word boundaries once it reaches the column cap instead of growing forever. | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |

## Math

Inline: Euler's identity $e^{i\pi} + 1 = 0$, a fraction \(\frac{a}{b}\) and the $x$-axis. Money stays money: it costs $5 and $10, and `echo $HOME and $PATH` is not math.

Display:

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

\[
\mathbf{A} = \begin{pmatrix} 1 & 2 & 3 \\ 4 & 5 & 6 \end{pmatrix}, \qquad \sum_{k=1}^{n} k = \frac{n(n+1)}{2}
\]

A display formula wider than any phone, which must scroll sideways:

$$
f(x) = a_0 + a_1 x + a_2 x^2 + a_3 x^3 + a_4 x^4 + a_5 x^5 + a_6 x^6 + a_7 x^7 + a_8 x^8 + a_9 x^9 + a_{10} x^{10} + a_{11} x^{11} + a_{12} x^{12}
$$

Unsupported TeX shows its source: $\unknowncommand{x}$.

## The rest

![Crok logo](https://crok-relay.vercel.app/icon.svg) (an image: shown as a link, never fetched)

Raw HTML stays text: <div class="x">not a div</div>

#### Heading 4
##### Heading 5
###### Heading 6
