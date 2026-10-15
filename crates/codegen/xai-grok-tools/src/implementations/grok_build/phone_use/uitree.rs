//! Android's accessibility tree, as `uiautomator dump` writes it.
//!
//! Every element is a `<node … bounds="[x1,y1][x2,y2]">` with flat attributes, so the dump is read
//! as attributes per node rather than as a document; a dump cut short by a screen change still
//! yields the nodes before the cut.

use std::sync::LazyLock;

use regex::Regex;

use super::text::{Source, TextBox};

static NODE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"<node\b((?:[^>"]|"[^"]*")*)>"#).expect("node pattern"));
static ATTRIBUTE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"([A-Za-z_][\w:-]*)="([^"]*)""#).expect("attribute pattern"));
static BOUNDS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$").expect("bounds pattern")
});

/// One element of the tree.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Node {
    pub text: String,
    pub desc: String,
    pub resource_id: String,
    pub class: String,
    pub package: String,
    pub clickable: bool,
    pub left: i64,
    pub top: i64,
    pub right: i64,
    pub bottom: i64,
}

impl Node {
    pub fn width(&self) -> i64 {
        self.right - self.left
    }

    pub fn height(&self) -> i64 {
        self.bottom - self.top
    }
}

/// The nodes of a dump, in document order. `None` when the output holds no tree at all, which is
/// what uiautomator prints instead of one when it fails.
pub fn parse(dump: &str) -> Option<Vec<Node>> {
    let start = dump.find("<hierarchy")?;
    let body = dump.get(start..)?;
    let mut nodes = Vec::new();
    for node in NODE.captures_iter(body) {
        let Some(attributes) = node.get(1) else {
            continue;
        };
        let mut n = Node::default();
        let mut bounds = None;
        for attribute in ATTRIBUTE.captures_iter(attributes.as_str()) {
            let (Some(key), Some(value)) = (attribute.get(1), attribute.get(2)) else {
                continue;
            };
            let value = unescape(value.as_str());
            match key.as_str() {
                "text" => n.text = value,
                "content-desc" => n.desc = value,
                "resource-id" => n.resource_id = value,
                "class" => n.class = value,
                "package" => n.package = value,
                "clickable" => n.clickable = value == "true",
                "bounds" => bounds = parse_bounds(&value),
                _ => {}
            }
        }
        let Some((left, top, right, bottom)) = bounds else {
            continue;
        };
        n.left = left;
        n.top = top;
        n.right = right;
        n.bottom = bottom;
        nodes.push(n);
    }
    Some(nodes)
}

fn parse_bounds(value: &str) -> Option<(i64, i64, i64, i64)> {
    let c = BOUNDS.captures(value)?;
    let n = |i: usize| c.get(i).and_then(|m| m.as_str().parse::<i64>().ok());
    Some((n(1)?, n(2)?, n(3)?, n(4)?))
}

/// XML's escapes, and the numeric references uiautomator writes for newlines.
fn unescape(value: &str) -> String {
    if !value.contains('&') {
        return value.to_owned();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        let Some(end) = tail.find(';').filter(|&end| end <= 10) else {
            out.push('&');
            rest = &tail[1..];
            continue;
        };
        let entity = &tail[1..end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => entity
                .strip_prefix("#x")
                .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                .or_else(|| entity.strip_prefix('#').and_then(|d| d.parse().ok()))
                .and_then(char::from_u32),
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &tail[end + 1..];
            }
            None => {
                out.push('&');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// The screen's size in the dump's own orientation: the bounds of its first, outermost node.
pub fn screen_size(nodes: &[Node]) -> Option<(f64, f64)> {
    let root = nodes.first()?;
    (root.width() > 0 && root.height() > 0).then_some((root.right as f64, root.bottom as f64))
}

/// What the model reads of the tree: every element with text or a description, and every
/// clickable element with neither, named by its resource id.
pub fn text_boxes(nodes: &[Node]) -> Vec<TextBox> {
    let mut boxes = Vec::new();
    for n in nodes {
        if n.width() <= 0 || n.height() <= 0 {
            continue;
        }
        let label = if n.text.trim().is_empty() {
            n.desc.trim()
        } else {
            n.text.trim()
        };
        let id = n
            .resource_id
            .rsplit_once(":id/")
            .map(|(_, id)| id)
            .unwrap_or(&n.resource_id)
            .trim();
        // A control with neither text nor an id gives the model nothing to name it by
        let unnamed_control = !n.clickable || id.is_empty();
        if label.is_empty() && unnamed_control {
            continue;
        }
        boxes.push(TextBox {
            text: label.to_owned(),
            x: (n.left + n.right) as f64 / 2.0,
            y: (n.top + n.bottom) as f64 / 2.0,
            width: n.width() as f64,
            height: n.height() as f64,
            source: Source::Tree,
            confidence: 1.0,
            clickable: n.clickable,
            id: (label.is_empty() && !id.is_empty()).then(|| id.to_owned()),
        });
    }
    boxes
}

#[cfg(test)]
mod tests {
    use super::*;

    const DUMP: &str = r#"<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.android.chrome" content-desc="" clickable="false" bounds="[0,0][1080,2400]"><node index="0" text="Search or type URL" resource-id="com.android.chrome:id/url_bar" class="android.widget.EditText" package="com.android.chrome" content-desc="" clickable="true" bounds="[160,140][900,260]" /><node index="1" text="" resource-id="com.android.chrome:id/menu_button" class="android.widget.ImageButton" package="com.android.chrome" content-desc="" clickable="true" bounds="[960,140][1080,260]" /><node index="2" text="" resource-id="" class="android.widget.ImageView" package="com.android.chrome" content-desc="Tom &amp; Jerry&#10;home" clickable="false" bounds="[0,300][200,400]" /><node index="3" text="" resource-id="" class="android.view.View" package="x" content-desc="" clickable="false" bounds="[0,0][0,0]" /></node></hierarchy>UI hierchary dumped to: /dev/tty"#;

    #[test]
    fn parses_nodes_and_their_bounds() {
        let nodes = parse(DUMP).unwrap();
        assert_eq!(nodes.len(), 5);
        assert_eq!(screen_size(&nodes), Some((1080.0, 2400.0)));
        assert_eq!(nodes[1].text, "Search or type URL");
        assert!(nodes[1].clickable);
        assert_eq!(nodes[3].desc, "Tom & Jerry\nhome");
        assert!(parse("ERROR: could not get idle state.").is_none());
    }

    #[test]
    fn the_model_sees_labels_and_unlabeled_buttons() {
        let boxes = text_boxes(&parse(DUMP).unwrap());
        let names: Vec<_> = boxes
            .iter()
            .map(|b| (b.text.as_str(), b.id.as_deref()))
            .collect();
        assert_eq!(
            names,
            vec![
                ("Search or type URL", None),
                ("", Some("menu_button")),
                ("Tom & Jerry\nhome", None),
            ]
        );
        assert_eq!((boxes[0].x, boxes[0].y), (530.0, 200.0));
    }

    #[test]
    fn unescapes_what_xml_escapes() {
        assert_eq!(
            unescape("a &lt;b&gt; &quot;c&quot; &#x41;"),
            "a <b> \"c\" A"
        );
        assert_eq!(unescape("AT&T"), "AT&T");
        assert_eq!(unescape("&unknown; x"), "&unknown; x");
    }
}
