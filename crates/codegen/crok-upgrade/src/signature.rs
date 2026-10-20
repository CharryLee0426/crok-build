//! Whether a new build keeps the permissions macOS gave the installed one.
//!
//! macOS keeps Accessibility, Screen Recording, the microphone and its other privacy permissions
//! for an app's identifier and the designated requirement of the signature it allowed, not for
//! the copy on disk. A requirement that names a certificate
//! (`identifier "dev.chenli.crok.desktop" and certificate leaf = H"…"`) is met by every later
//! build signed with it; an ad hoc one (`cdhash H"…"`) only by that one build. So an update keeps
//! the permissions exactly when the new code meets the installed code's requirement, and that is
//! checked before anything is replaced.

use std::path::Path;
use std::process::Command;

/// What installing the new code does to the permissions of the code it replaces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Permissions {
    /// The new code meets the installed code's requirement, so macOS keeps what it allowed.
    Kept,
    /// The installed code is signed ad hoc or not at all: no other build could keep its
    /// permissions, so macOS asks again whatever is installed.
    NothingToKeep,
    /// The installed code names a signer that did not sign the new code.
    Lost { requirement: String, reason: String },
}

impl Permissions {
    /// One word for the JSON events.
    pub fn label(&self) -> &'static str {
        match self {
            Permissions::Kept => "kept",
            Permissions::NothingToKeep => "none",
            Permissions::Lost { .. } => "lost",
        }
    }
}

/// Compares the new code at `new` with the installed code at `installed`, an app bundle or an
/// executable.
pub fn compare(installed: &Path, new: &Path) -> Permissions {
    let Some(requirement) = designated_requirement(installed).filter(|req| names_a_signer(req)) else {
        return Permissions::NothingToKeep;
    };
    match meets(new, &requirement) {
        Ok(()) => Permissions::Kept,
        Err(reason) => Permissions::Lost { requirement, reason },
    }
}

/// Compares an installed Crok Desktop with the staged new one: the app, and the `crok` inside it,
/// which has a requirement of its own. The first loss wins.
pub fn compare_app(installed: &Path, new: &Path) -> Permissions {
    let crok = Path::new("Contents/Resources/crok");
    let app = compare(installed, new);
    if matches!(app, Permissions::Lost { .. }) || !installed.join(crok).is_file() {
        return app;
    }
    match compare(&installed.join(crok), &new.join(crok)) {
        lost @ Permissions::Lost { .. } => lost,
        Permissions::Kept => Permissions::Kept,
        Permissions::NothingToKeep => app,
    }
}

/// Whether the installed code's permissions can outlive an update: its requirement names a
/// signer, so a new build either meets it or is refused.
pub fn carries_over(installed: &Path) -> bool {
    designated_requirement(installed).is_some_and(|req| names_a_signer(&req))
}

/// The designated requirement of the code at `path`, as `codesign -d -r-` prints it. None for
/// unsigned code, and where there is no codesign.
pub fn designated_requirement(path: &Path) -> Option<String> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let output = Command::new("/usr/bin/codesign")
        .args(["-d", "-r-"])
        .arg(path)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_requirement(&String::from_utf8_lossy(&output.stdout))
        .or_else(|| parse_requirement(&String::from_utf8_lossy(&output.stderr)))
}

/// The requirement in `codesign -d -r-` output. An implicit one (`# designated => cdhash H"…"`,
/// what the linker gives an unsigned build) counts as well.
fn parse_requirement(text: &str) -> Option<String> {
    text.lines()
        .find_map(|line| {
            let line = line.trim_start().trim_start_matches('#').trim_start();
            line.strip_prefix("designated =>").map(|req| req.trim().to_string())
        })
        .filter(|req| !req.is_empty())
}

/// Whether a requirement names a signer, which later builds can meet, rather than one build's hash.
fn names_a_signer(requirement: &str) -> bool {
    requirement.contains("certificate") || requirement.contains("anchor")
}

/// Whether the code at `path` is intact and meets `requirement`, and if not, codesign's reason.
fn meets(path: &Path, requirement: &str) -> Result<(), String> {
    let output = Command::new("/usr/bin/codesign")
        .args(["--verify", "--strict", "-R"])
        .arg(format!("={requirement}"))
        .arg(path)
        .output()
        .map_err(|error| format!("running codesign: {error}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requirements_are_read_from_codesign_output() {
        let signed = "Executable=/Applications/Crok Desktop.app/Contents/MacOS/GrokDesktop\n\
                      designated => identifier \"dev.chenli.crok.desktop\" and certificate leaf = H\"4d47\"\n";
        assert_eq!(
            parse_requirement(signed).as_deref(),
            Some("identifier \"dev.chenli.crok.desktop\" and certificate leaf = H\"4d47\"")
        );
        let linker = "# designated => cdhash H\"65208debc1ae387085711e415702ff4935cded28\"\n";
        assert_eq!(
            parse_requirement(linker).as_deref(),
            Some("cdhash H\"65208debc1ae387085711e415702ff4935cded28\"")
        );
        assert_eq!(parse_requirement("Executable=/bin/x\n"), None);
    }

    #[test]
    fn only_a_named_signer_outlives_a_build() {
        assert!(names_a_signer("identifier \"dev.chenli.crok\" and certificate leaf = H\"4d47\""));
        assert!(names_a_signer("identifier \"com.apple.ls\" and anchor apple"));
        assert!(!names_a_signer("cdhash H\"65208debc1ae387085711e415702ff4935cded28\""));
    }

    /// Ad hoc code names only its own hash, so there is nothing to keep, and a requirement naming
    /// a certificate is not met by it.
    #[cfg(target_os = "macos")]
    #[test]
    fn ad_hoc_code_has_nothing_to_keep_and_meets_no_certificate() {
        let dir = tempfile::tempdir().unwrap();
        let installed = dir.path().join("installed");
        let new = dir.path().join("new");
        for path in [&installed, &new] {
            std::fs::copy("/usr/bin/true", path).unwrap();
            let output = Command::new("/usr/bin/codesign")
                .args(["--force", "--sign", "-", "--identifier", "dev.chenli.crok.unit-test"])
                .arg(path)
                .output()
                .unwrap();
            assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        }
        assert!(!carries_over(&installed));
        assert_eq!(compare(&installed, &new), Permissions::NothingToKeep);
        let requirement = "identifier \"dev.chenli.crok.unit-test\" and certificate leaf = H\"4d47861c871242056da13d30e3874a36be0aa14c\"";
        assert!(meets(&new, requirement).is_err());
        assert!(meets(&new, "identifier \"dev.chenli.crok.unit-test\"").is_ok());
        assert!(meets(&new, "identifier \"dev.chenli.crok.other\"").is_err());
    }
}
