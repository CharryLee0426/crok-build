use super::*;

fn commands(names: &[&str]) -> Vec<acp::AvailableCommand> {
    names
        .iter()
        .map(|&name| acp::AvailableCommand::new(name, String::new()))
        .collect()
}

/// The shell advertises after every model response; an unchanged catalog must not look like a
/// new generation, or the prompt rebuilds every slash trigger each turn.
#[test]
fn an_unchanged_catalog_keeps_the_generation() {
    let mut session = crate::app::agent::tests::test_session();
    // Bootstrap seeds generation 1; the fixture starts at 0.
    session.available_commands_generation = 1;
    session.replace_available_commands(
        commands(&["alpha", "beta"]),
        CommandCatalogSource::SessionUpdate,
    );
    let generation = session.available_commands_generation;
    assert!(
        generation > 1,
        "the first real catalog bumps past the bootstrap seed"
    );

    session.replace_available_commands(
        commands(&["alpha", "beta"]),
        CommandCatalogSource::SessionUpdate,
    );
    assert_eq!(
        session.available_commands_generation, generation,
        "same names, same descriptions"
    );

    let mut renamed = commands(&["alpha", "beta"]);
    renamed[1].description = "beta does more now".to_owned();
    session.replace_available_commands(renamed, CommandCatalogSource::SessionUpdate);
    assert_eq!(
        session.available_commands_generation,
        generation + 1,
        "a changed description is a new catalog"
    );

    session.replace_available_commands(commands(&["alpha"]), CommandCatalogSource::SessionUpdate);
    assert_eq!(
        session.available_commands_generation,
        generation + 2,
        "a removed name is a new catalog"
    );
}

#[test]
fn command_name_diff_reports_added_and_removed_sorted() {
    let prev = commands(&["alpha", "beta"]);
    let next = commands(&["gamma", "alpha", "delta"]);
    assert_eq!(
        command_name_diff(&prev, &next),
        (
            vec!["delta".to_owned(), "gamma".to_owned()],
            vec!["beta".to_owned()]
        )
    );
}
