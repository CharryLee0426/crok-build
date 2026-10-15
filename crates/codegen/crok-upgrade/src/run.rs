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

/// After Crok Desktop quits, how long another copy opened from the same bundle (from the Dock, a
/// moment after the quit) may take to quit as well.
const OTHER_COPIES_TIMEOUT: Duration = Duration::from_secs(30);

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
    let latest_text = release.version.to_string();
    let (wanted, mut no_asset_reason) = match wanted_asset(&target, &release.version) {
        Ok(wanted) => (Some(wanted), None),
        Err(error) => (None, Some(format!("{error:#}"))),
    };
    // The signed manifest is the list of what the release carries. A release without the file
    // this copy takes (the disk image for the SDK it was built with) is not offered.
    let manifest = match &wanted {
        Some(_) if update_available || options.force => {
            Some(release::fetch_manifest(&source, &release.tag, &keys).await?)
        }
        _ => None,
    };
    if let (Some(manifest), Some(wanted)) = (&manifest, &wanted)
        && manifest.find(&wanted.name).is_none()
    {
        no_asset_reason = Some(missing_asset(wanted, &latest_text));
    }
    reporter.event(json!({
        "event": "check",
        "current": current.to_string(),
        "latest": latest_text,
        "tag": release.tag,
        "page": release.page_url,
        "notes": release.notes,
        "updateAvailable": update_available,
        "target": target.kind(),
        "targetPath": target.path(),
        "asset": wanted.as_ref().map(|wanted| &wanted.name),
        "sdk": wanted.as_ref().and_then(|wanted| wanted.linked_sdk).map(|(major, minor)| format!("{major}.{minor}")),
        "image": wanted.as_ref().and_then(|wanted| wanted.image).map(assets::DiskImage::sdk),
        "unavailable": no_asset_reason,
    }));
    let current_text = current.to_string();
    if update_available {
        reporter.text(msg(
            "upgrade.available",
            "crok release {latest} is available; this is {current}.",
            &[("latest", &latest_text), ("current", &current_text)],
        ));
        reporter.text(msg("upgrade.notes", "Release notes: {url}", &[("url", &release.page_url)]));
        if let Some(reason) = &no_asset_reason {
            reporter.text(reason);
        } else if options.check_only {
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

    let (asset_name, manifest) = match (wanted, manifest, no_asset_reason) {
        (Some(wanted), Some(manifest), None) => (wanted.name, manifest),
        (_, _, reason) => bail!("{}", reason.unwrap_or_default()),
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
                // Crok Desktop installs the update whenever it quits, however long that takes;
                // it cancels with SIGTERM.
                reporter.status("waiting", msg("upgrade.waiting", "Waiting for Crok Desktop to quit…", &[]));
                install::wait_for_exit(pid, None).await?;
                // Nobody reads this output any more. What happens next is written down for the
                // app's next launch, and the app is opened again even when the swap failed, so
                // the person is never left without it.
                let outcome = swap_when_closed(&staged, bundle, &previous).await;
                install::record_result(&install::InstallResult {
                    version: version_text.clone(),
                    previous: previous.clone(),
                    installed: outcome.is_ok(),
                    message: outcome.as_ref().err().map(|error| format!("{error:#}")),
                });
                if options.relaunch {
                    reporter.status("relaunch", msg("upgrade.relaunching", "Opening Crok Desktop…", &[]));
                    let _ = install::relaunch(bundle);
                }
                outcome?;
            } else {
                if !install::running_pids(bundle).is_empty() {
                    bail!("{}", desktop_running());
                }
                swap_when_closed(&staged, bundle, &previous).await?;
                if options.relaunch {
                    reporter.status("relaunch", msg("upgrade.relaunching", "Opening Crok Desktop…", &[]));
                    install::relaunch(bundle)?;
                }
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

/// Moves the staged app into place once no copy of the installed one runs any more.
async fn swap_when_closed(staged: &install::StagedApp, bundle: &Path, previous: &str) -> Result<()> {
    if !install::wait_for_bundle_to_close(bundle, OTHER_COPIES_TIMEOUT).await {
        bail!("{}", desktop_running());
    }
    let old = install::swap_app(staged, bundle)?;
    let bundle_name = bundle
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Crok Desktop.app".to_string());
    install::discard_old_app(&old, &bundle_name, previous);
    Ok(())
}

/// The release file this installation takes.
struct Wanted {
    name: String,
    /// For Crok Desktop: the SDK its executable was linked against, and so its disk image.
    linked_sdk: Option<(u32, u32)>,
    image: Option<assets::DiskImage>,
}

fn wanted_asset(target: &Target, version: &semver::Version) -> Result<Wanted> {
    let arch = assets::arch_label();
    match target {
        Target::App { bundle } => {
            let linked = assets::app_linked_sdk(bundle)?;
            let image = assets::DiskImage::for_linked_sdk(linked.0);
            Ok(Wanted {
                name: assets::app_asset_name(version, arch, image),
                linked_sdk: Some(linked),
                image: Some(image),
            })
        }
        Target::Binary { .. } => {
            let name = assets::binary_asset_name(version, arch).with_context(|| {
                format!(
                    "releases carry no crok for {} {}; build it from source",
                    std::env::consts::OS,
                    arch
                )
            })?;
            Ok(Wanted {
                name,
                linked_sdk: None,
                image: None,
            })
        }
    }
}

/// Why a newer release cannot be installed here: it lacks this copy's file.
fn missing_asset(wanted: &Wanted, version: &str) -> String {
    match wanted.image {
        Some(image) => msg(
            "upgrade.no_image",
            "Release {version} has no {asset}. This copy of Crok Desktop was built with the macOS {sdk} SDK and only installs that disk image.",
            &[("version", version), ("asset", &wanted.name), ("sdk", &image.sdk().to_string())],
        ),
        None => msg(
            "upgrade.no_binary",
            "Release {version} has no {asset} for this machine.",
            &[("version", version), ("asset", &wanted.name)],
        ),
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
