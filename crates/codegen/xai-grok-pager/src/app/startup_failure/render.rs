use super::{ConnectAttempt, Context, EarlierAttempt, Reason, StartupFailure};
use crate::app::connect_timeout::CONNECT_UI_TIMEOUT_TRY_COMMAND;
use std::fmt::Write as _;
use std::time::Duration;
use unicode_width::UnicodeWidthStr;
use xai_grok_i18n::{sentence_gap, tl, tlf};
use xai_grok_telemetry::startup::{AgentKind, PhaseSnapshot, StartupPhase, format_duration};
const WRAP_WIDTH: usize = 76;
pub(super) fn render(failure: &StartupFailure) -> String {
    let context = &failure.context;
    let mut rows = vec![
        (tl("Mode"), attempted_agents(context)),
        (tl("Version"), context.version.clone()),
    ];
    let mut report = match &failure.reason {
        Reason::TimedOut { waited, timings } => {
            let advice = advice_for(timings, context.attempt);
            rows.push((tl("Steps"), format_steps(timings)));
            if let Some(command) = advice.next_step.command() {
                rows.push((tl("Try"), command.to_owned()));
            }
            let explanation = fill_indented(&advice.explanation(), "  ", "  ");
            format!(
                "{}\n\n{explanation}",
                tlf(
                    "Couldn't start Crok: startup timed out after {time}.",
                    &[("time", &whole_seconds(*waited))]
                )
            )
        }
        Reason::Cancelled => tlf(
            "Startup cancelled while connecting to the {agent}.",
            &[("agent", &agent_name(context.target))],
        ),
    };
    rows.push((tl("Log"), context.log_path.display().to_string()));
    let _ = write!(report, "\n\n{}", label_rows(&rows));
    report
}
struct Advice {
    doing: Option<&'static str>,
    earlier: Option<EarlierAttempt>,
    next_step: NextStep,
}
/// A wedged leader is only ever the earlier attempt: the fallback that renders this message never enters `LeaderConnect` itself.
fn advice_for(timings: &PhaseSnapshot, attempt: ConnectAttempt) -> Advice {
    let step = timings.longest_step().map(step_advice);
    let earlier = attempt.earlier();
    Advice {
        doing: step.map(|(doing, _)| doing),
        earlier: earlier.filter(|earlier| earlier.shaped_the_wait()),
        next_step: if earlier.is_some_and(|earlier| earlier.wedged_leader()) {
            NextStep::RestartSharedLeader
        } else {
            step.map_or(NextStep::Retry, |(_, next_step)| next_step)
        },
    }
}
impl Advice {
    fn explanation(&self) -> String {
        let mut explanation = match self.doing {
            Some(doing) => tlf("The longest step was {step}.", &[("step", &doing)]),
            None => tl("No startup step had begun.").to_owned(),
        };
        let gap = sentence_gap();
        if let Some(earlier) = self.earlier {
            let target = agent_name(earlier.target);
            let _ = write!(
                explanation,
                "{gap}{}",
                tlf(
                    "Crok spent the first {time} on the {agent}.",
                    &[("time", &whole_seconds(earlier.wait)), ("agent", &target)]
                )
            );
        }
        let _ = write!(explanation, "{gap}{}", self.next_step.text());
        if matches!(
            self.next_step,
            NextStep::Retry | NextStep::CheckNetworkThenRetry
        ) {
            let _ = write!(
                explanation,
                "{gap}{}",
                tl(
                    "On a slow machine or network filesystem, a larger startup budget can help. Set it with the command below."
                )
            );
        }
        explanation
    }
}
fn format_steps(timings: &PhaseSnapshot) -> String {
    let completed = timings
        .completed
        .iter()
        .map(|&(phase, elapsed)| (phase, elapsed, ""));
    let open = timings.open.map(|(phase, elapsed)| (phase, elapsed, "+"));
    let steps: Vec<String> = completed
        .chain(open)
        .map(|(phase, elapsed, still_running)| {
            format!(
                "{}={}{still_running}",
                phase.label(),
                format_duration(elapsed)
            )
        })
        .collect();
    if steps.is_empty() {
        return tl("none").to_owned();
    }
    steps.join(", ")
}
/// Values hang under their label, so a wrapped one never reads as a new field.
fn label_rows(rows: &[(&str, String)]) -> String {
    let column_width = rows
        .iter()
        .map(|(label, _)| label.width() + ":".len())
        .max()
        .unwrap_or(0);
    rows.iter()
        .map(|(label, value)| {
            let padding = " ".repeat(column_width.saturating_sub(label.width() + ":".len()));
            let label = format!("  {label}:{padding} ");
            let hanging = " ".repeat(label.width());
            fill_indented(value, &label, &hanging)
        })
        .collect::<Vec<_>>()
        .join("\n")
}
fn fill_indented(text: &str, initial_indent: &str, subsequent_indent: &str) -> String {
    textwrap::fill(
        text,
        textwrap::Options::new(WRAP_WIDTH)
            .initial_indent(initial_indent)
            .subsequent_indent(subsequent_indent)
            .break_words(false)
            .wrap_algorithm(textwrap::WrapAlgorithm::FirstFit),
    )
}
#[derive(Clone, Copy)]
enum NextStep {
    Retry,
    CheckNetworkThenRetry,
    RestartSharedLeader,
}
impl NextStep {
    fn text(self) -> &'static str {
        match self {
            Self::Retry => tl("Start Crok again."),
            Self::CheckNetworkThenRetry => {
                tl("Check your network connection, then start Crok again.")
            }
            Self::RestartSharedLeader => tl(
                "Stop it with the command below, which also stops any other Crok session using it, then start Crok again.",
            ),
        }
    }
    /// Kept out of the prose so wrapping can never split it.
    fn command(self) -> Option<&'static str> {
        match self {
            Self::Retry | Self::CheckNetworkThenRetry => Some(CONNECT_UI_TIMEOUT_TRY_COMMAND),
            Self::RestartSharedLeader => Some("crok leader kill"),
        }
    }
}
/// Reads as the object of "The longest step was".
fn step_advice(phase: StartupPhase) -> (&'static str, NextStep) {
    use NextStep::{CheckNetworkThenRetry as Network, RestartSharedLeader, Retry};
    match phase {
        StartupPhase::ConfigLoad => (tl("reading your local configuration"), Retry),
        StartupPhase::ManagedPolicy => (tl("checking your organization's managed policy"), Network),
        StartupPhase::Bootstrap => (tl("loading your account settings"), Network),
        StartupPhase::ModelCatalog => (tl("reading the list of available models"), Retry),
        StartupPhase::WorkerSpawn => (tl("starting the local agent"), Retry),
        StartupPhase::LeaderConnect => (tl("connecting to the shared leader"), RestartSharedLeader),
        StartupPhase::AcpInitialize => (tl("waiting for the agent to respond"), Retry),
        StartupPhase::EagerAuth => (tl("refreshing your sign-in"), Network),
        StartupPhase::AppInit => (tl("preparing the interface"), Retry),
        StartupPhase::SessionCreate => (tl("creating the session"), Retry),
    }
}
fn attempted_agents(context: &Context) -> String {
    let target = agent_name(context.target);
    match context.attempt {
        ConnectAttempt::First => target.to_owned(),
        ConnectAttempt::AfterFallback(earlier) => tlf(
            "{first}, then {second}",
            &[("first", &agent_name(earlier.target)), ("second", &target)],
        ),
    }
}
fn agent_name(agent: AgentKind) -> &'static str {
    match agent {
        AgentKind::Embedded => tl("local agent"),
        AgentKind::Leader => tl("shared leader"),
    }
}
/// Rounded: a truncated total can print smaller than the steps it sums.
pub(super) fn whole_seconds(wait: Duration) -> String {
    format!("{}s", (wait.as_millis() + 500) / 1000)
}
