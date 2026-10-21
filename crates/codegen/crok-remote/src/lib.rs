//! Remote control: this computer's link to the crok relay (a Convex deployment, see `relay/DESIGN.md`).
//!
//! - [`login`] signs the computer in with the device flow and [`credentials`] keeps the result in
//!   `$CROK_HOME/remote/credentials.json` (0600; `credentials-dev.json` in test builds, see `relay/environments`).
//! - [`link`] is the network side of a running crok process: it holds the WebSocket to the relay on its own thread,
//!   mirrors sessions there and hands commands from phones back to the agent.
//! - [`cli`] is `crok remote login | logout | status`.
//!
//! Remote sign-in is unrelated to model-provider sign-in (`crok login <provider>`): it only links this computer to the
//! person's relay account.

pub mod api;
pub mod cli;
pub mod credentials;
pub mod link;
pub mod login;
pub mod qr;
pub mod settings;
pub mod types;

pub use credentials::Credentials;
pub use types::{EventInput, EventKind, HostApp, InboxCommand, SessionFields, SessionStatus};
