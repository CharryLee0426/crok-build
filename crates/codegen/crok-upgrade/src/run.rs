//! The `crok upgrade` command.

use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde_json::json;

use crate::assets::{self, Target};
use crate::install;
use crate::release::{self, Source};
use crate::report::Reporter;
use crate::sshsig::TrustedKeys;

/// How long the staged app waits for Crok Desktop to quit before giving up.
const QUIT_TIMEOUT: Duration = Duration::from_secs(15 * 60);

#[derive(Debug, Clone, Default)]
pub struct Options {
    /// Report whether a newer release exists and stop.
    pub check_only: bool,
    /// One JSON object per line on stdout, for Crok Desktop.
    pub json: bool,
    /// Install the latest release even when it is not newer.
    pub force: bool,
    /// Wait for this process (Crok Desktop) to exit before the bundle is swapped.
    pub wait_for_pid: Option<u32>,
    /// Open the app again once it is installed.
    pub relaunch: bool,
    /// Check a release folder's manifest and signature instead of upgrading.
    pub verify_dir: Option<PathBuf>,
    /// The release version this build carries.
    pub current_release: String,
}

pub async fn run(options: Options) -> Result<()> {
    let mut reporter = Reporter::new(options.json);
    let result = run_inner(&options, &mut reporter).await;
    if let Err(error) = &result {
        reporter.end_progress();
        reporter.event(json!({ "event": "error", "message": format!("{error:#}") }));
    }
    result
}

async fn run_inner(options: &Options, reporter: &mut Reporter) -> Result<()> {
    let keys = TrustedKeys::parse(crate::TRUSTED_KEYS).context("the built-in release keys")?;
    if let Some(dir) = &options.verify_dir {
        return verify_local(dir, &keys, reporter);
    }

    let current = semver::Version::parse(options.current_release.trim())
        .unwrap_or_else(|_| semver::Version::new(0, 0, 0));
    let exe = std::env::current_exe().context("locating this executable")?;
    let target = assets::detect_target(&exe)?;
    let source = Source::from_env();

    reporter.status("check", msg("upgrade.checking", "Checking for a newer crok release…", &[]));
    let release = release::latest(&source, options.check_only).await?;
    let update_available = release.version > current;
    let (asset_name, no_asset_reason) = match wanted_asset(&target, &release.version) {
        Ok(name) => (Some(name), None),
        Err(error) => (None, Some(format!("{error:#}"))),
    };
    reporter.event(json!({
        "event": "check",
        "current": current.to_string(),
        "latest": release.version.to_string(),
        "tag": release.tag,
        "page": release.page_url,
        "notes": release.notes,
        "updateAvailable": update_available,
        "target": target.kind(),
        "targetPath": target.path(),
        "asset": asset_name,
        "unavailable": no_asset_reason,
    }));
    let current_text = current.to_string();
    let latest_text = release.version.to_string();
    if update_available {
        reporter.text(msg(
            "upgrade.available",
            "crok release {latest} is available; this is {current}.",
            &[("latest", &latest_text), ("current", &current_text)],
        ));
        reporter.text(msg("upgrade.notes", "Release notes: {url}", &[("url", &release.page_url)]));
        if options.check_only {
            reporter.text(msg("upgrade.check_hint", "Run `crok upgrade` to install it.", &[]));
        }
    } else {
        reporter.text(msg(
            "upgrade.up_to_date",
            "crok release {current} is the latest.",
            &[("current", &current_text)],
        ));
    }
    if options.check_only || (!update_available && !options.force) {
        return Ok(());
    }

    let asset_name = match asset_name {
        Some(name) => name,
        None => bail!("{}", no_asset_reason.unwrap_or_default()),
    };
    assets::check_target(&target)?;
    if let Target::App { bundle } = &target {
        if install::is_test_build(bundle) && std::env::var_os("CROK_UPGRADE_ALLOW_TEST_BUILD").is_none() {
            bail!(
                "{} is a workspace test build; rebuild it with make build-test-desktop",
                bundle.display()
            );
        }
        if options.wait_for_pid.is_none() && !install::running_pids(bundle).is_empty() {
            bail!("{}", desktop_running());
        }
    }

    let manifest = release::fetch_manifest(&source, &release.tag, &keys).await?;
    let Some((name, expected_hash)) = manifest.find(&asset_name) else {
        let listed: Vec<&str> = manifest.names().collect();
        bail!(
            "release {} has no {asset_name} for this machine (it carries: {})",
            release.tag,
            listed.join(", ")
        );
    };
    let name = name.to_string();
    let expected_hash = expected_hash.to_string();

    let cache = xai_dirs::grok_home().join("updates").join(&release.tag);
    let download = cache.join(&name);
    let cached = download.is_file() && release::sha256_file(&download).ok().as_deref() == Some(expected_hash.as_str());
    if !cached {
        reporter.status("download", msg("upgrade.downloading", "Downloading {asset}…", &[("asset", &name)]));
        let url = source.asset_url(&release.tag, &name);
        release::download(&url, &download, |received, total| reporter.progress(received, total)).await?;
        reporter.end_progress();
        reporter.status("verify", msg("upgrade.verifying", "Verifying the download…", &[]));
        let actual = release::sha256_file(&download)?;
        if actual != expected_hash {
            let _ = std::fs::remove_file(&download);
            bail!("{name} does not match the checksum in the signed {}", crate::MANIFEST_NAME);
        }
    }

    let version_text = release.version.to_string();
    match &target {
        Target::Binary { path } => {
            reporter.status("install", msg("upgrade.installing", "Installing…", &[]));
            install::install_binary(&download, path)?;
            reporter.event(json!({ "event": "installed", "version": version_text, "path": path }));
            reporter.text(msg(
                "upgrade.installed_binary",
                "Installed crok release {version} at {path}.",
                &[("version", &version_text), ("path", &path.display().to_string())],
            ));
        }
        Target::App { bundle } => {
            reporter.status("install", msg("upgrade.installing", "Installing…", &[]));
            let staged = install::stage_app(&download, bundle, &version_text)?;
            let previous = install::bundle_version(bundle).unwrap_or_else(|_| "previous".to_string());
            reporter.event(json!({ "event": "ready", "version": version_text }));
            if let Some(pid) = options.wait_for_pid {
                reporter.status("waiting", format!("Waiting for Crok Desktop (process {pid}) to quit…"));
                install::wait_for_exit(pid, QUIT_TIMEOUT).await?;
            }
            if !install::running_pids(bundle).is_empty() {
                bail!("{}", desktop_running());
            }
            let old = install::swap_app(&staged, bundle)?;
            let bundle_name = bundle
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_else(|| "Crok Desktop.app".to_string());
            install::discard_old_app(&old, &bundle_name, &previous);
            if options.relaunch {
                reporter.status("relaunch", "Opening Crok Desktop…");
                install::relaunch(bundle)?;
            }
            reporter.event(json!({ "event": "installed", "version": version_text, "path": bundle }));
            reporter.text(msg(
                "upgrade.installed_app",
                "Installed Crok Desktop {version} at {path}. Its crok command is updated with it.",
                &[("version", &version_text), ("path", &bundle.display().to_string())],
            ));
        }
    }
    let _ = std::fs::remove_dir_all(&cache);
    if let Some(updates) = cache.parent() {
        // Only when nothing else is cached; a non-empty folder makes this fail, which is fine.
        let _ = std::fs::remove_dir(updates);
    }
    Ok(())
}

fn wanted_asset(target: &Target, version: &semver::Version) -> Result<String> {
    let arch = assets::arch_label();
    match target {
        Target::App { .. } => {
            let major = assets::macos_major().context("Crok Desktop upgrades need macOS")?;
            Ok(assets::app_asset_name(version, arch, major))
        }
        Target::Binary { .. } => assets::binary_asset_name(version, arch).with_context(|| {
            format!(
                "releases carry no crok for {} {}; build it from source",
                std::env::consts::OS,
                arch
            )
        }),
    }
}

fn desktop_running() -> String {
    msg(
        "upgrade.desktop_running",
        "Crok Desktop is running. Quit it and run `crok upgrade` again, or use Crok Desktop › Check for Updates…",
        &[],
    )
}

/// Checks a release folder the way an installing crok would, before it is published.
fn verify_local(dir: &Path, keys: &TrustedKeys, reporter: &mut Reporter) -> Result<()> {
    let manifest_path = dir.join(crate::MANIFEST_NAME);
    let signature_path = dir.join(crate::SIGNATURE_NAME);
    let text = std::fs::read(&manifest_path).with_context(|| format!("reading {}", manifest_path.display()))?;
    let signature = std::fs::read_to_string(&signature_path)
        .with_context(|| format!("reading {}", signature_path.display()))?;
    let manifest = release::Manifest::parse(text)?;
    manifest.verify(&signature, keys)?;
    reporter.text(format!(
        "{} is signed by a key this crok trusts ({} trusted).",
        crate::MANIFEST_NAME,
        keys.len()
    ));
    let mut checked = Vec::new();
    for name in manifest.names() {
        let path = dir.join(name);
        if !path.is_file() {
            bail!("{} lists {name}, which is not in {}", crate::MANIFEST_NAME, dir.display());
        }
        let actual = release::sha256_file(&path)?;
        let (_, expected) = manifest.find(name).context("listed file")?;
        if actual != expected {
            bail!("{name} does not match its checksum");
        }
        reporter.text(format!("ok  {name}"));
        checked.push(name.to_string());
    }
    reporter.event(json!({ "event": "verified", "files": checked }));
    Ok(())
}

/// A localized message with `{name}` placeholders filled in.
fn msg(key: &str, fallback: &str, values: &[(&str, &str)]) -> String {
    let mut text = xai_grok_i18n::t_or(key, fallback).to_string();
    for (name, value) in values {
        text = text.replace(&format!("{{{name}}}"), value);
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholders_are_filled() {
        assert_eq!(
            msg("upgrade.nonexistent", "{a} and {b}", &[("a", "1"), ("b", "2")]),
            "1 and 2"
        );
    }

    #[test]
    fn built_in_keys_parse() {
        let keys = TrustedKeys::parse(crate::TRUSTED_KEYS).unwrap();
        assert!(!keys.is_empty());
    }
}
