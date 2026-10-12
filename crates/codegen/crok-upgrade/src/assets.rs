//! Which file in a release this installation needs, and where it goes.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

/// What `crok upgrade` replaces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// This crok is `Contents/Resources/crok` inside a Crok Desktop bundle: the whole app is
    /// replaced, which carries the TUI with it.
    App { bundle: PathBuf },
    /// A standalone `crok` binary (for example `~/.local/bin/crok` from `make deploy`).
    Binary { path: PathBuf },
}

impl Target {
    pub fn path(&self) -> &Path {
        match self {
            Target::App { bundle } => bundle,
            Target::Binary { path } => path,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Target::App { .. } => "app",
            Target::Binary { .. } => "binary",
        }
    }
}

/// Classifies the running executable. `CROK_UPGRADE_TARGET` names another bundle or binary to
/// upgrade instead, which the tests and the release check use.
pub fn detect_target(exe: &Path) -> Result<Target> {
    if let Some(forced) = std::env::var_os("CROK_UPGRADE_TARGET").filter(|v| !v.is_empty()) {
        let forced = dunce::canonicalize(&forced)
            .with_context(|| format!("CROK_UPGRADE_TARGET {}", Path::new(&forced).display()))?;
        return Ok(if forced.extension().is_some_and(|ext| ext == "app") {
            Target::App { bundle: forced }
        } else {
            Target::Binary { path: forced }
        });
    }
    let exe = dunce::canonicalize(exe).with_context(|| format!("locating {}", exe.display()))?;
    Ok(classify(&exe))
}

fn classify(exe: &Path) -> Target {
    // <bundle>.app/Contents/Resources/crok
    if exe.file_name().is_some_and(|name| name == "crok")
        && let Some(resources) = exe.parent()
        && resources.file_name().is_some_and(|name| name == "Resources")
        && let Some(contents) = resources.parent()
        && contents.file_name().is_some_and(|name| name == "Contents")
        && let Some(bundle) = contents.parent()
        && bundle.extension().is_some_and(|ext| ext == "app")
    {
        return Target::App {
            bundle: bundle.to_path_buf(),
        };
    }
    Target::Binary {
        path: exe.to_path_buf(),
    }
}

/// Refuses targets an upgrade must not touch.
pub fn check_target(target: &Target) -> Result<()> {
    let path = target.path();
    if path
        .components()
        .any(|component| component.as_os_str() == "target")
        && path.ancestors().any(|dir| dir.join("Cargo.toml").is_file())
    {
        bail!(
            "{} is a build in a source checkout. Upgrade a source build with `git pull` and `make deploy`.",
            path.display()
        );
    }
    if path.to_string_lossy().contains("/AppTranslocation/") {
        bail!("Crok Desktop runs from a translocated copy. Move it to Applications and open it again.");
    }
    let parent = path
        .parent()
        .with_context(|| format!("{} has no parent folder", path.display()))?;
    let probe = tempfile::Builder::new()
        .prefix(".crok-upgrade-")
        .tempfile_in(parent);
    if probe.is_err() {
        bail!(
            "{} is not writable, so the upgrade cannot replace {}",
            parent.display(),
            path.display()
        );
    }
    Ok(())
}

/// `arm64` or `x86_64`, as the release file names spell it.
pub fn arch_label() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "arm64",
        other => other,
    }
}

/// The major macOS version, from `sw_vers`.
pub fn macos_major() -> Option<u32> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    let output = std::process::Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.trim().split('.').next()?.parse().ok()
}

/// The disk image for this Mac. Liquid Glass needs an app built with the macOS 26 SDK, which
/// does not run on macOS 15, so a release carries one image per SDK.
pub fn app_asset_name(version: &semver::Version, arch: &str, macos_major: u32) -> String {
    let sdk = if macos_major >= 26 { 26 } else { 15 };
    format!("Crok-Desktop-{version}-{arch}-macOS{sdk}-SDK.dmg")
}

/// The standalone TUI tarball for this platform, when releases carry one.
pub fn binary_asset_name(version: &semver::Version, arch: &str) -> Option<String> {
    let platform = match std::env::consts::OS {
        "macos" => "apple-darwin",
        "linux" => "unknown-linux-gnu",
        _ => return None,
    };
    let arch = if arch == "arm64" { "aarch64" } else { arch };
    Some(format!("crok-{version}-{arch}-{platform}.tar.gz"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_harness_is_an_app_target() {
        let exe = Path::new("/Applications/Crok Desktop.app/Contents/Resources/crok");
        assert_eq!(
            classify(exe),
            Target::App {
                bundle: PathBuf::from("/Applications/Crok Desktop.app")
            }
        );
        let exe = Path::new("/Users/me/.local/bin/crok");
        assert_eq!(
            classify(exe),
            Target::Binary {
                path: exe.to_path_buf()
            }
        );
        let exe = Path::new("/Applications/Crok Desktop.app/Contents/Resources/bin/crok");
        assert!(matches!(classify(exe), Target::Binary { .. }));
    }

    #[test]
    fn asset_names() {
        let version = semver::Version::new(1, 5, 0);
        assert_eq!(
            app_asset_name(&version, "arm64", 26),
            "Crok-Desktop-1.5.0-arm64-macOS26-SDK.dmg"
        );
        assert_eq!(
            app_asset_name(&version, "arm64", 27),
            "Crok-Desktop-1.5.0-arm64-macOS26-SDK.dmg"
        );
        assert_eq!(
            app_asset_name(&version, "arm64", 15),
            "Crok-Desktop-1.5.0-arm64-macOS15-SDK.dmg"
        );
        assert_eq!(
            app_asset_name(&version, "arm64", 14),
            "Crok-Desktop-1.5.0-arm64-macOS15-SDK.dmg"
        );
        if cfg!(target_os = "macos") {
            assert_eq!(
                binary_asset_name(&version, "arm64").unwrap(),
                "crok-1.5.0-aarch64-apple-darwin.tar.gz"
            );
        }
    }

    #[test]
    fn source_builds_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("Cargo.toml"), "[workspace]\n").unwrap();
        let exe = dir.path().join("target/release/xai-grok-pager");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, b"").unwrap();
        let error = check_target(&Target::Binary { path: exe }).unwrap_err();
        assert!(error.to_string().contains("source checkout"), "{error}");

        let plain = dir.path().join("bin/crok");
        std::fs::create_dir_all(plain.parent().unwrap()).unwrap();
        std::fs::write(&plain, b"").unwrap();
        check_target(&Target::Binary { path: plain }).unwrap();
    }
}
