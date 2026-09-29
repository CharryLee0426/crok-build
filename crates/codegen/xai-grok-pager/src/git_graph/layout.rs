//! Lane layout for the commit graph: one row per commit, lanes that stay put, and joins drawn
//! within a row.
//!
//! Crok Desktop's Git Graph window lays history out with the same algorithm (`GitGraph.swift`),
//! so a repository reads the same in both.
//!
//! Commits must come children-first (`git log --topo-order`). Each lane waits for one commit
//! hash. A commit takes the leftmost lane waiting for it, or a free one when nothing is (a branch
//! tip). Other lanes waiting for it end at it (branches that forked here). Its first parent
//! inherits its lane and colour; each further parent joins the lane already waiting for it, or
//! opens a new lane with a new colour. A slot freed on a row is not reused on that same row, so a
//! lane that ends is never mistaken for one that starts.

/// A line between the commit's node and another lane within one row.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Edge {
    pub lane: usize,
    /// Palette index of the line.
    pub color: usize,
    /// For `branches_out`: the lane starts on this row (it had nothing above).
    pub new: bool,
}

/// How one commit's row is drawn.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Row {
    /// The lane holding the commit's node.
    pub column: usize,
    /// Palette index of the node and its lane.
    pub color: usize,
    /// The node's lane comes from the row above (false for a branch tip).
    pub up: bool,
    /// The node's lane continues below (false for a root commit).
    pub down: bool,
    /// Each lane's colour at the top of the row, `None` where no lane runs.
    pub above: Vec<Option<usize>>,
    /// Each lane's colour at the bottom of the row.
    pub below: Vec<Option<usize>>,
    /// Lanes from above that end at this commit: its other children's branches.
    pub merges_in: Vec<Edge>,
    /// Lanes below that this commit's second and later parents continue in.
    pub branches_out: Vec<Edge>,
}

impl Row {
    /// Lanes this row spans, including the node's.
    pub fn width(&self) -> usize {
        self.above.len().max(self.below.len()).max(self.column + 1)
    }

    /// A lane that runs straight through this row without ending at the node.
    pub fn passes_through(&self, lane: usize) -> bool {
        lane != self.column
            && self.above.get(lane).copied().flatten().is_some()
            && !self.merges_in.iter().any(|edge| edge.lane == lane)
    }
}

#[derive(Clone, Copy)]
struct Lane<'a> {
    target: &'a str,
    color: usize,
}

/// Lays out commits given children-first as `(hash, parents)`.
pub fn layout<'a, P>(commits: impl IntoIterator<Item = (&'a str, P)>) -> Vec<Row>
where
    P: IntoIterator<Item = &'a str>,
{
    let mut lanes: Vec<Option<Lane<'a>>> = Vec::new();
    let mut next_color = 0;
    let mut rows = Vec::new();
    for (hash, parents) in commits {
        let parents: Vec<&'a str> = parents.into_iter().collect();
        let above: Vec<Option<usize>> = lanes.iter().map(|lane| lane.map(|l| l.color)).collect();
        let existing = lanes
            .iter()
            .position(|lane| lane.is_some_and(|lane| lane.target == hash));
        let column = existing.unwrap_or_else(|| {
            let slot = lanes
                .iter()
                .position(Option::is_none)
                .unwrap_or(lanes.len());
            put(
                &mut lanes,
                slot,
                Lane {
                    target: hash,
                    color: next_color,
                },
            );
            next_color += 1;
            slot
        });
        let color = color_of(&lanes, column);

        let mut merges_in = Vec::new();
        for (index, slot) in lanes.iter_mut().enumerate() {
            if index != column
                && let Some(lane) = slot
                && lane.target == hash
            {
                merges_in.push(Edge {
                    lane: index,
                    color: lane.color,
                    new: false,
                });
                *slot = None;
            }
        }

        if let Some(slot) = lanes.get_mut(column) {
            match (parents.first(), slot.as_mut()) {
                (Some(first), Some(lane)) => lane.target = first,
                _ => *slot = None,
            }
        }

        let mut branches_out = Vec::new();
        for &parent in parents.iter().skip(1) {
            let waiting = lanes.iter().enumerate().position(|(index, lane)| {
                index != column && lane.is_some_and(|lane| lane.target == parent)
            });
            if let Some(index) = waiting {
                branches_out.push(Edge {
                    lane: index,
                    color: color_of(&lanes, index),
                    new: false,
                });
                continue;
            }
            let free = lanes.iter().enumerate().position(|(index, lane)| {
                index != column && lane.is_none() && above.get(index).copied().flatten().is_none()
            });
            let index = free.unwrap_or(lanes.len());
            put(
                &mut lanes,
                index,
                Lane {
                    target: parent,
                    color: next_color,
                },
            );
            branches_out.push(Edge {
                lane: index,
                color: next_color,
                new: true,
            });
            next_color += 1;
        }

        while lanes.last().is_some_and(Option::is_none) {
            lanes.pop();
        }
        let below = lanes.iter().map(|lane| lane.map(|l| l.color)).collect();
        rows.push(Row {
            column,
            color,
            up: existing.is_some(),
            down: !parents.is_empty(),
            above,
            below,
            merges_in,
            branches_out,
        });
    }
    rows
}

/// Puts `lane` in slot `index`, at most one past the end.
fn put<'a>(lanes: &mut Vec<Option<Lane<'a>>>, index: usize, lane: Lane<'a>) {
    match lanes.get_mut(index) {
        Some(slot) => *slot = Some(lane),
        None => lanes.push(Some(lane)),
    }
}

fn color_of(lanes: &[Option<Lane<'_>>], index: usize) -> usize {
    lanes
        .get(index)
        .copied()
        .flatten()
        .map_or(0, |lane| lane.color)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `("c", "b a")` is commit `c` with parents `b` then `a`.
    fn rows(history: &[(&'static str, &'static str)]) -> Vec<Row> {
        layout(
            history
                .iter()
                .map(|(hash, parents)| (*hash, parents.split_whitespace())),
        )
    }

    #[test]
    fn linear_history_stays_in_one_lane_and_colour() {
        let rows = rows(&[("c", "b"), ("b", "a"), ("a", "")]);
        assert_eq!(rows.len(), 3);
        for row in &rows {
            assert_eq!(row.column, 0);
            assert_eq!(row.color, 0);
            assert!(row.merges_in.is_empty() && row.branches_out.is_empty());
        }
        assert!(!rows[0].up && rows[0].down, "the tip has nothing above");
        assert!(rows[1].up && rows[1].down);
        assert!(rows[2].up && !rows[2].down, "the root ends the lane");
        assert_eq!(rows[2].below, Vec::<Option<usize>>::new());
    }

    #[test]
    fn branch_and_merge() {
        // m merges feature (f) into main (b); both forked from a.
        let rows = rows(&[("m", "b f"), ("f", "a"), ("b", "a"), ("a", "")]);
        // The merge opens a new lane for its second parent.
        assert_eq!(rows[0].column, 0);
        assert_eq!(
            rows[0].branches_out,
            vec![Edge {
                lane: 1,
                color: 1,
                new: true
            }]
        );
        assert_eq!(rows[0].below, vec![Some(0), Some(1)]);
        // f sits in that lane, b in main's; b passes lane 1 through.
        assert_eq!((rows[1].column, rows[1].color), (1, 1));
        assert!(rows[1].passes_through(0));
        assert_eq!((rows[2].column, rows[2].color), (0, 0));
        assert!(rows[2].passes_through(1));
        // Both lanes wait for a; it takes the leftmost and the other ends there.
        assert_eq!(rows[3].column, 0);
        assert_eq!(
            rows[3].merges_in,
            vec![Edge {
                lane: 1,
                color: 1,
                new: false
            }]
        );
        assert!(!rows[3].passes_through(1));
    }

    #[test]
    fn a_branch_tip_opens_a_new_lane_with_a_new_colour() {
        // Two tips: main (b) and topic (t), both on a.
        let rows = rows(&[("b", "a"), ("t", "a"), ("a", "")]);
        assert_eq!((rows[0].column, rows[0].color, rows[0].up), (0, 0, false));
        assert_eq!((rows[1].column, rows[1].color, rows[1].up), (1, 1, false));
        assert_eq!(rows[1].above, vec![Some(0)]);
        assert_eq!(rows[1].below, vec![Some(0), Some(1)]);
        assert_eq!(rows[2].merges_in.len(), 1);
    }

    #[test]
    fn several_children_converge_on_their_parent() {
        let rows = rows(&[("x", "a"), ("y", "a"), ("z", "a"), ("a", "")]);
        assert_eq!(rows[3].column, 0);
        let lanes: Vec<usize> = rows[3].merges_in.iter().map(|edge| edge.lane).collect();
        assert_eq!(lanes, vec![1, 2]);
        assert_eq!(rows[3].below, Vec::<Option<usize>>::new());
    }

    #[test]
    fn octopus_merge_opens_a_lane_per_extra_parent() {
        let rows = rows(&[
            ("o", "a b c"),
            ("c", "r"),
            ("b", "r"),
            ("a", "r"),
            ("r", ""),
        ]);
        let out: Vec<(usize, bool)> = rows[0]
            .branches_out
            .iter()
            .map(|edge| (edge.lane, edge.new))
            .collect();
        assert_eq!(out, vec![(1, true), (2, true)]);
        assert_eq!(rows[0].below, vec![Some(0), Some(1), Some(2)]);
        assert_eq!(rows[1].column, 2);
        assert_eq!(rows[2].column, 1);
        assert_eq!(rows[4].merges_in.len(), 2);
    }

    #[test]
    fn a_merge_joins_a_lane_already_waiting_for_its_parent() {
        // t and m both reach f; m's second parent f is already waited for by t's lane.
        let rows = rows(&[("t", "f"), ("m", "a f"), ("f", "a"), ("a", "")]);
        assert_eq!(rows[1].column, 1);
        assert_eq!(
            rows[1].branches_out,
            vec![Edge {
                lane: 0,
                color: 0,
                new: false
            }]
        );
        assert!(rows[1].passes_through(0));
    }

    #[test]
    fn a_root_commit_ends_its_lane_and_frees_the_slot_for_later_rows() {
        // Two unrelated histories: x (root) then y → z.
        let rows = rows(&[("y", "z"), ("x", ""), ("z", "")]);
        assert_eq!((rows[1].column, rows[1].down), (1, false));
        assert_eq!(
            rows[1].below,
            vec![Some(0)],
            "trailing empty lanes are trimmed"
        );
        assert_eq!(rows[2].column, 0);
    }

    #[test]
    fn a_slot_freed_on_a_row_is_not_reused_on_that_row() {
        // m's children x (lane 0) and y (lane 1) both converge on m; m is also a merge.
        // The freed lane 1 must not carry m's second parent on the same row.
        let rows = rows(&[("x", "m"), ("y", "m"), ("m", "a b"), ("b", "a"), ("a", "")]);
        let row = &rows[2];
        assert_eq!(row.column, 0);
        assert_eq!(row.merges_in.len(), 1);
        assert_eq!(row.merges_in[0].lane, 1);
        assert_eq!(row.branches_out.len(), 1);
        assert_eq!(row.branches_out[0].lane, 2);
        assert!(row.branches_out[0].new);
        assert_eq!(
            row.below,
            vec![Some(0), None, Some(row.branches_out[0].color)]
        );
    }

    #[test]
    fn colours_follow_the_first_parent_chain() {
        let rows = rows(&[
            ("m2", "m1 f2"),
            ("f2", "f1"),
            ("m1", "m0"),
            ("f1", "m0"),
            ("m0", ""),
        ]);
        let main = rows[0].color;
        assert_eq!(rows[2].color, main);
        assert_eq!(rows[4].color, main);
        let feature = rows[1].color;
        assert_ne!(feature, main);
        assert_eq!(rows[3].color, feature);
    }
}
