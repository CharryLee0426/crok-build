//! The destination built into this crok (`build.rs`): where every install reports unless
//! `~/.crok/agento11y.env` says otherwise.

include!(concat!(env!("OUT_DIR"), "/builtin_destination.rs"));

/// The built-in settings, in the `agento11y.env` format; `None` when this build has none.
pub(crate) fn text() -> Option<String> {
    if BUILTIN_MASKED.is_empty() {
        return None;
    }
    let bytes = BUILTIN_MASKED
        .iter()
        .zip(BUILTIN_MASK.iter().cycle())
        .map(|(byte, mask)| byte ^ mask)
        .collect();
    String::from_utf8(bytes).ok()
}
