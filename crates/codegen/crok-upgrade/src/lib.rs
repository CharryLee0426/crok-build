//! Self-update for crok and Crok Desktop.
//!
//! Every release of the fork is one GitHub release carrying the Crok Desktop disk images and a
//! tarball of the standalone `crok` binary, plus `SHA256SUMS.txt` and its `ssh-keygen -Y`
//! signature. The public key of the release signer is compiled into this crate; nothing a
//! release page says is trusted until the manifest's signature checks against it.
//!
//! The same code serves both front ends: `crok upgrade` in a terminal and "Check for Updates…"
//! in Crok Desktop, which runs its bundled `crok upgrade --json`.

pub mod assets;
pub mod install;
pub mod release;
mod report;
mod run;
pub mod sshsig;

pub use run::{Options, run};

/// The release signing keys, one `ssh-ed25519` line per trusted key. Rotate by adding a line
/// and shipping a release that carries both before removing the old one.
pub const TRUSTED_KEYS: &str = include_str!("../../../../release/crok-release.pub");

/// The namespace `ssh-keygen -Y sign -n` must use for a release manifest.
pub const SIGNATURE_NAMESPACE: &str = "crok-release";

/// The manifest and signature file names inside a release.
pub const MANIFEST_NAME: &str = "SHA256SUMS.txt";
pub const SIGNATURE_NAME: &str = "SHA256SUMS.txt.sig";
