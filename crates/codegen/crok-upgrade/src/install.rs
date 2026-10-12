//! Putting a verified download in place: a standalone binary is renamed over, a Crok Desktop
//! bundle is staged beside the installed one and swapped in with two renames.
//!
//! Nothing is ever overwritten in place. macOS kills a process whose signed executable
//! changes under it, and a rename leaves the running copy's files untouched.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

/// Replaces `target` with the `crok` executable inside the release tarball.
pub fn install_binary(archive: &Path, target: &Path) -> Result<()> {
    let dir = target
        .parent()
        .with_context(|| format!("{} has no parent folder", target.display()))?;
    let file = std::fs::File::open(archive).with_context(|| format!("opening {}", archive.display()))?;
    let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(file));
    let mut staged = None;
    for entry in tar.entries().context("reading the archive")? {
        let mut entry = entry.context("reading the archive")?;
        if !entry.header().entry_type().is_file() {
            continue;
        }
        let is_crok = entry
            .path()
            .ok()
            .and_then(|path| path.file_name().map(|name| name == "crok"))
            .unwrap_or(false);
        if !is_crok {
            continue;
        }
        let mut temp = tempfile::Builder::new()
            .prefix(".crok-upgrade-")
            .tempfile_in(dir)
            .with_context(|| format!("writing into {}", dir.display()))?;
        std::io::copy(&mut entry, &mut temp).context("extracting crok")?;
        staged = Some(temp);
        break;
    }
    let staged = staged.context("the archive holds no crok executable")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(staged.path(), std::fs::Permissions::from_mode(0o755))?;
    }
    clear_quarantine(staged.path());
    let probe = Command::new(staged.path())
        .arg("--version")
        .env("CROK_DISABLE_AUTOUPDATER", "1")
        .output()
        .context("running the downloaded crok")?;
    if !probe.status.success() {
        bail!(
            "the downloaded crok does not run on this machine: {}",
            String::from_utf8_lossy(&probe.stderr).trim()
        );
    }
    staged
        .persist(target)
        .with_context(|| format!("replacing {}", target.display()))?;
    Ok(())
}

/// A copy of the new app, staged in a hidden folder beside the installed bundle so the final
/// move is a rename on the same volume. Dropping it removes whatever was not moved out.
pub struct StagedApp {
    _folder: tempfile::TempDir,
    pub app: PathBuf,
    pub version: String,
}

/// Mounts the disk image, copies its app beside `bundle`, and checks the copy.
pub fn stage_app(dmg: &Path, bundle: &Path, expected_version: &str) -> Result<StagedApp> {
    let parent = bundle
        .parent()
        .with_context(|| format!("{} has no parent folder", bundle.display()))?;
    let folder = tempfile::Builder::new()
        .prefix(".crok-upgrade-")
        .tempdir_in(parent)
        .with_context(|| format!("staging in {}", parent.display()))?;
    let mount = MountedImage::attach(dmg)?;
    let source = std::fs::read_dir(&mount.path)
        .with_context(|| format!("reading {}", mount.path.display()))?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .find(|path| path.extension().is_some_and(|ext| ext == "app"))
        .context("the disk image holds no app")?;
    let app = folder.path().join(
        bundle
            .file_name()
            .with_context(|| format!("{} has no name", bundle.display()))?,
    );
    let status = Command::new("/usr/bin/ditto")
        .arg(&source)
        .arg(&app)
        .status()
        .context("running ditto")?;
    if !status.success() {
        bail!("copying {} failed", source.display());
    }
    drop(mount);

    let version = bundle_version(&app)?;
    if version != expected_version {
        bail!("the disk image holds Crok Desktop {version}, not {expected_version}");
    }
    let verify = Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict"])
        .arg(&app)
        .output()
        .context("running codesign")?;
    if !verify.status.success() {
        bail!(
            "the downloaded app's signature is damaged: {}",
            String::from_utf8_lossy(&verify.stderr).trim()
        );
    }
    clear_quarantine(&app);
    Ok(StagedApp {
        _folder: folder,
        app,
        version,
    })
}

struct MountedImage {
    path: PathBuf,
    _dir: tempfile::TempDir,
}

impl MountedImage {
    fn attach(dmg: &Path) -> Result<Self> {
        let dir = tempfile::Builder::new()
            .prefix("crok-upgrade-")
            .tempdir()
            .context("creating a mount point")?;
        let path = dir.path().join("image");
        std::fs::create_dir(&path)?;
        let output = Command::new("/usr/bin/hdiutil")
            .args(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint"])
            .arg(&path)
            .arg(dmg)
            .output()
            .context("running hdiutil")?;
        if !output.status.success() {
            bail!(
                "opening the disk image failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(Self { path, _dir: dir })
    }
}

impl Drop for MountedImage {
    fn drop(&mut self) {
        for attempt in 0..5 {
            if attempt > 0 {
                std::thread::sleep(Duration::from_secs(1));
            }
            let detached = Command::new("/usr/bin/hdiutil")
                .args(["detach", "-quiet"])
                .arg(&self.path)
                .status()
                .is_ok_and(|status| status.success());
            if detached {
                return;
            }
        }
        let _ = Command::new("/usr/bin/hdiutil")
            .args(["detach", "-force", "-quiet"])
            .arg(&self.path)
            .status();
    }
}

/// `CFBundleShortVersionString` of an app.
pub fn bundle_version(bundle: &Path) -> Result<String> {
    plist_value(bundle, "CFBundleShortVersionString")
        .with_context(|| format!("{} has no version", bundle.display()))
}

/// Workspace test apps carry `GrokDesktopTestBuild`; an upgrade would turn one into the real app.
pub fn is_test_build(bundle: &Path) -> bool {
    plist_value(bundle, "GrokDesktopTestBuild").is_some_and(|value| value == "true")
}

fn plist_value(bundle: &Path, key: &str) -> Option<String> {
    let output = Command::new("/usr/libexec/PlistBuddy")
        .arg("-c")
        .arg(format!("Print :{key}"))
        .arg(bundle.join("Contents/Info.plist"))
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Processes running an executable from inside `bundle`, other than this one.
pub fn running_pids(bundle: &Path) -> Vec<u32> {
    let Ok(output) = Command::new("/bin/ps").args(["-axo", "pid=,comm="]).output() else {
        return Vec::new();
    };
    let needle = format!("{}/Contents/MacOS/", bundle.display());
    let me = std::process::id();
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| {
            let (pid, command) = line.trim().split_once(char::is_whitespace)?;
            let pid: u32 = pid.parse().ok()?;
            (pid != me && command.trim_start().starts_with(&needle)).then_some(pid)
        })
        .collect()
}

/// Waits until `pid` has exited. A SIGTERM (Crok Desktop cancelling the install) ends the wait
/// with an error, so the staged copy is dropped and removed on the way out.
pub async fn wait_for_exit(pid: u32, timeout: Duration) -> Result<()> {
    #[cfg(unix)]
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .context("listening for SIGTERM")?;
    let started = Instant::now();
    while process_exists(pid) {
        if started.elapsed() > timeout {
            bail!("process {pid} is still running after {} seconds", timeout.as_secs());
        }
        #[cfg(unix)]
        tokio::select! {
            _ = terminate.recv() => bail!("the install was cancelled"),
            _ = tokio::time::sleep(Duration::from_millis(200)) => {}
        }
        #[cfg(not(unix))]
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Ok(())
}

#[cfg(unix)]
fn process_exists(pid: u32) -> bool {
    // SAFETY: kill with signal 0 only probes for the process; it sends nothing.
    let result = unsafe { libc::kill(pid as libc::pid_t, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn process_exists(_pid: u32) -> bool {
    false
}

/// Moves the installed bundle aside and the staged app into its place. Returns where the old
/// bundle went; on failure the old bundle is back where it was.
pub fn swap_app(staged: &StagedApp, bundle: &Path) -> Result<PathBuf> {
    let parent = bundle
        .parent()
        .with_context(|| format!("{} has no parent folder", bundle.display()))?;
    let name = bundle
        .file_name()
        .and_then(|name| name.to_str())
        .with_context(|| format!("{} has no name", bundle.display()))?;
    let old = parent.join(format!(".{name}.old-{}", std::process::id()));
    std::fs::rename(bundle, &old).with_context(|| format!("moving {} aside", bundle.display()))?;
    if let Err(error) = std::fs::rename(&staged.app, bundle) {
        let _ = std::fs::rename(&old, bundle);
        return Err(error).with_context(|| format!("moving the new app to {}", bundle.display()));
    }
    // Finder and the Dock refresh an app's icon and version from its modification time.
    let _ = Command::new("/usr/bin/touch").arg(bundle).status();
    Ok(old)
}

/// The replaced bundle goes to the Trash under its version, as a way back; if the Trash is on
/// another volume it is deleted.
pub fn discard_old_app(old: &Path, bundle_name: &str, version: &str) {
    let stem = bundle_name.strip_suffix(".app").unwrap_or(bundle_name);
    if let Some(trash) = xai_dirs::home_dir().map(|home| home.join(".Trash"))
        && trash.is_dir()
    {
        for attempt in 0..100 {
            let name = if attempt == 0 {
                format!("{stem} {version}.app")
            } else {
                format!("{stem} {version} {attempt}.app")
            };
            let destination = trash.join(name);
            if destination.exists() {
                continue;
            }
            if std::fs::rename(old, &destination).is_ok() {
                return;
            }
            break;
        }
    }
    let _ = std::fs::remove_dir_all(old);
}

/// Opens the app, as a fresh process.
pub fn relaunch(bundle: &Path) -> Result<()> {
    let status = Command::new("/usr/bin/open")
        .arg(bundle)
        .status()
        .context("running open")?;
    if !status.success() {
        bail!("opening {} failed", bundle.display());
    }
    Ok(())
}

/// A download made by crok carries no quarantine, but a copy made by hand might; the flag
/// would make macOS judge the new app as a fresh download. Best effort.
pub fn clear_quarantine(path: &Path) {
    if cfg!(target_os = "macos") {
        let _ = Command::new("/usr/bin/xattr")
            .args(["-d", "-r", "-s", "com.apple.quarantine"])
            .arg(path)
            .output();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_install_extracts_crok_and_replaces_the_target() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("crok");
        std::fs::write(&target, b"old").unwrap();
        let archive = dir.path().join("crok.tar.gz");
        {
            let file = std::fs::File::create(&archive).unwrap();
            let encoder = flate2::write::GzEncoder::new(file, flate2::Compression::fast());
            let mut builder = tar::Builder::new(encoder);
            let script = b"#!/bin/sh\necho crok 9.9.9\n";
            let mut header = tar::Header::new_gnu();
            header.set_size(script.len() as u64);
            header.set_mode(0o755);
            header.set_cksum();
            builder.append_data(&mut header, "crok", &script[..]).unwrap();
            builder.into_inner().unwrap().finish().unwrap();
        }
        install_binary(&archive, &target).unwrap();
        assert!(std::fs::read_to_string(&target).unwrap().contains("9.9.9"));
        assert!(
            std::fs::read_dir(dir.path())
                .unwrap()
                .filter_map(|entry| entry.ok())
                .all(|entry| !entry.file_name().to_string_lossy().starts_with(".crok-upgrade-"))
        );
    }

    #[test]
    fn binary_install_refuses_an_archive_without_crok() {
        let dir = tempfile::tempdir().unwrap();
        let archive = dir.path().join("other.tar.gz");
        {
            let file = std::fs::File::create(&archive).unwrap();
            let encoder = flate2::write::GzEncoder::new(file, flate2::Compression::fast());
            let mut builder = tar::Builder::new(encoder);
            let mut header = tar::Header::new_gnu();
            header.set_size(1);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, "README", &b"x"[..]).unwrap();
            builder.into_inner().unwrap().finish().unwrap();
        }
        let target = dir.path().join("crok");
        std::fs::write(&target, b"old").unwrap();
        assert!(install_binary(&archive, &target).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"old");
    }

    #[tokio::test]
    async fn this_process_exists_and_a_dead_pid_does_not() {
        assert!(process_exists(std::process::id()));
        wait_for_exit(u32::MAX - 7, Duration::from_secs(1)).await.unwrap();
    }
}
