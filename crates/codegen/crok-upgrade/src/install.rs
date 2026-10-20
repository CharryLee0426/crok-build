//! Putting a verified download in place. A standalone binary is renamed over the old one, at the
//! same path. Crok Desktop is updated inside its own bundle: the new app is staged beside it and
//! its `Contents` exchanged with the installed one's in a single rename, so the bundle folder
//! stays, with what macOS attached to it, and no second copy of the app is left anywhere.
//!
//! No file is ever overwritten in place. macOS kills a process whose signed executable
//! changes under it, and a rename leaves the running copy's files untouched.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};

/// The new `crok`, extracted beside the binary it replaces and run once. Dropping it removes it.
pub struct StagedBinary {
    file: tempfile::NamedTempFile,
}

impl StagedBinary {
    pub fn path(&self) -> &Path {
        self.file.path()
    }

    /// Renames the new binary over `target`.
    pub fn install(self, target: &Path) -> Result<()> {
        self.file
            .persist(target)
            .with_context(|| format!("replacing {}", target.display()))?;
        Ok(())
    }
}

/// Extracts the `crok` executable inside the release tarball beside `target`, and checks it runs.
pub fn stage_binary(archive: &Path, target: &Path) -> Result<StagedBinary> {
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
    Ok(StagedBinary { file: staged })
}

/// A copy of the new app, staged in a hidden folder beside the installed bundle so the final
/// exchange is a rename on the same volume. Dropping it removes the folder, and with it the old
/// contents once they have been exchanged for the new.
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
    sweep_stale_staging(parent);
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

pub(crate) fn plist_value(bundle: &Path, key: &str) -> Option<String> {
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

/// Waits until `pid` has exited, for at most `timeout` when one is given. A SIGTERM (Crok
/// Desktop cancelling the install) ends the wait with an error, so the staged copy is dropped
/// and removed on the way out. Once the wait is over, SIGTERM no longer stops this process, so
/// a swap that has begun is not cut in half.
pub async fn wait_for_exit(pid: u32, timeout: Option<Duration>) -> Result<()> {
    #[cfg(unix)]
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .context("listening for SIGTERM")?;
    let started = Instant::now();
    while process_exists(pid) {
        if let Some(timeout) = timeout
            && started.elapsed() > timeout
        {
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

/// Waits until nothing runs from inside `bundle`. False when something still does after `timeout`.
pub async fn wait_for_bundle_to_close(bundle: &Path, timeout: Duration) -> bool {
    let started = Instant::now();
    loop {
        if running_pids(bundle).is_empty() {
            return true;
        }
        if started.elapsed() > timeout {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
}

/// What became of an install that finished after Crok Desktop quit, for its next launch to show.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct InstallResult {
    pub version: String,
    pub previous: String,
    pub installed: bool,
    pub message: Option<String>,
}

/// `$CROK_HOME/updates/last-install.json`, which Crok Desktop reads and removes when it opens.
pub fn result_path() -> PathBuf {
    xai_dirs::grok_home().join("updates").join("last-install.json")
}

/// Writes the result where the next launch finds it. Best effort.
pub fn record_result(result: &InstallResult) {
    let path = result_path();
    let Some(dir) = path.parent() else { return };
    let _ = std::fs::create_dir_all(dir);
    let Ok(text) = serde_json::to_vec_pretty(result) else { return };
    if let Ok(mut file) = tempfile::NamedTempFile::new_in(dir) {
        use std::io::Write;
        if file.write_all(&text).is_ok() {
            let _ = file.persist(&path);
        }
    }
}

/// Staging folders an earlier install left beside the app when it was killed outright.
fn sweep_stale_staging(parent: &Path) {
    let Ok(entries) = std::fs::read_dir(parent) else { return };
    let day = Duration::from_secs(24 * 60 * 60);
    for entry in entries.filter_map(|entry| entry.ok()) {
        let stale = entry.file_name().to_string_lossy().starts_with(".crok-upgrade-")
            && entry
                .metadata()
                .and_then(|meta| meta.modified())
                .ok()
                .and_then(|modified| modified.elapsed().ok())
                .is_some_and(|age| age > day);
        if stale {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
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

/// How the new version was put in place.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Installed {
    /// Into the installed bundle: the folder stayed and only its `Contents` changed.
    InPlace,
    /// macOS refused changes inside the bundle, so the whole bundle was replaced at its path.
    Replaced,
}

/// Puts the staged app into the installed bundle. The bundle's `Contents` and the staged app's are
/// exchanged in one atomic rename, so the bundle folder keeps its identity and what macOS attached
/// to it, and the old contents end up in the staging folder, which goes when `staged` is dropped.
/// The old version is not kept as a second app, which LaunchServices would know as another Crok
/// Desktop. On failure the installed bundle is as it was.
pub fn update_bundle(staged: &StagedApp, bundle: &Path) -> Result<Installed> {
    let how = match exchange(&bundle.join("Contents"), &staged.app.join("Contents")) {
        Ok(()) => Installed::InPlace,
        // App Management can refuse changes inside an app bundle and still allow replacing the
        // bundle as a whole; the permissions follow the signature either way.
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            let old = swap_app(staged, bundle)?;
            let _ = std::fs::remove_dir_all(old);
            Installed::Replaced
        }
        Err(error) => return Err(error).with_context(|| format!("updating {}", bundle.display())),
    };
    // A copy dragged in from a downloaded disk image keeps the quarantine flag on its folder,
    // which would make macOS assess the new code as a fresh download.
    clear_quarantine(bundle);
    // Finder and the Dock refresh an app's icon and version from its modification time, and
    // LaunchServices rereads the bundle's Info.plist when told that it changed.
    let _ = Command::new("/usr/bin/touch").arg(bundle).status();
    register(bundle);
    Ok(how)
}

/// Swaps what two paths on one volume name: atomically where the volume can (`renamex_np` with
/// `RENAME_SWAP`, which APFS does), otherwise with three renames that are undone on failure.
fn exchange(a: &Path, b: &Path) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;
        let from = std::ffi::CString::new(a.as_os_str().as_bytes())?;
        let to = std::ffi::CString::new(b.as_os_str().as_bytes())?;
        // SAFETY: both are NUL-terminated paths that outlive the call.
        if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_SWAP) } == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if !matches!(error.raw_os_error(), Some(libc::ENOTSUP | libc::EINVAL)) {
            return Err(error);
        }
    }
    let aside = b.with_file_name(format!(".exchange-{}", std::process::id()));
    std::fs::rename(a, &aside)?;
    if let Err(error) = std::fs::rename(b, a) {
        let _ = std::fs::rename(&aside, a);
        return Err(error);
    }
    if let Err(error) = std::fs::rename(&aside, b) {
        let _ = std::fs::rename(a, b);
        let _ = std::fs::rename(&aside, a);
        return Err(error);
    }
    Ok(())
}

/// Moves the installed bundle aside and the staged app into its place. Returns where the old
/// bundle went; on failure the old bundle is back where it was.
fn swap_app(staged: &StagedApp, bundle: &Path) -> Result<PathBuf> {
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
    Ok(old)
}

/// Tells LaunchServices that the app changed. Best effort.
fn register(bundle: &Path) {
    const LSREGISTER: &str =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
    if cfg!(target_os = "macos") && bundle.join("Contents/Info.plist").is_file() {
        let _ = Command::new(LSREGISTER).arg("-f").arg(bundle).output();
    }
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
        stage_binary(&archive, &target).unwrap().install(&target).unwrap();
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
        assert!(stage_binary(&archive, &target).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"old");
    }

    /// An installed bundle with one marker file, and a staged app beside it with another.
    fn bundle_and_staged(dir: &Path) -> (PathBuf, StagedApp) {
        let bundle = dir.join("Crok Desktop.app");
        std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
        std::fs::write(bundle.join("Contents/MacOS/GrokDesktop"), b"old").unwrap();
        let folder = tempfile::Builder::new().prefix(".crok-upgrade-").tempdir_in(dir).unwrap();
        let app = folder.path().join("Crok Desktop.app");
        std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        std::fs::write(app.join("Contents/MacOS/GrokDesktop"), b"new").unwrap();
        let staged = StagedApp {
            _folder: folder,
            app,
            version: "9.9.9".to_string(),
        };
        (bundle, staged)
    }

    #[test]
    fn an_update_goes_into_the_installed_bundle_and_leaves_no_old_copy() {
        use std::os::unix::fs::MetadataExt;
        let dir = tempfile::tempdir().unwrap();
        let (bundle, staged) = bundle_and_staged(dir.path());
        let inode = std::fs::metadata(&bundle).unwrap().ino();
        if cfg!(target_os = "macos") {
            let status = Command::new("/usr/bin/xattr")
                .args(["-w", "dev.chenli.crok.unit-test", "kept"])
                .arg(&bundle)
                .status()
                .unwrap();
            assert!(status.success());
        }

        assert_eq!(update_bundle(&staged, &bundle).unwrap(), Installed::InPlace);
        assert_eq!(std::fs::read(bundle.join("Contents/MacOS/GrokDesktop")).unwrap(), b"new");
        assert_eq!(std::fs::metadata(&bundle).unwrap().ino(), inode);
        if cfg!(target_os = "macos") {
            let output = Command::new("/usr/bin/xattr")
                .args(["-p", "dev.chenli.crok.unit-test"])
                .arg(&bundle)
                .output()
                .unwrap();
            assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "kept");
        }
        // The old contents wait in the staging folder until it is dropped.
        assert_eq!(std::fs::read(staged.app.join("Contents/MacOS/GrokDesktop")).unwrap(), b"old");
        drop(staged);
        let left: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(left, vec![std::ffi::OsString::from("Crok Desktop.app")]);
    }

    #[test]
    fn a_failed_update_leaves_the_installed_bundle_as_it_was() {
        let dir = tempfile::tempdir().unwrap();
        let (bundle, staged) = bundle_and_staged(dir.path());
        std::fs::remove_dir_all(staged.app.join("Contents")).unwrap();
        assert!(update_bundle(&staged, &bundle).is_err());
        assert_eq!(std::fs::read(bundle.join("Contents/MacOS/GrokDesktop")).unwrap(), b"old");
    }

    #[test]
    fn exchange_swaps_two_folders() {
        let dir = tempfile::tempdir().unwrap();
        let a = dir.path().join("a");
        let b = dir.path().join("b");
        for (path, marker) in [(&a, "from a"), (&b, "from b")] {
            std::fs::create_dir(path).unwrap();
            std::fs::write(path.join("marker"), marker).unwrap();
        }
        exchange(&a, &b).unwrap();
        assert_eq!(std::fs::read_to_string(a.join("marker")).unwrap(), "from b");
        assert_eq!(std::fs::read_to_string(b.join("marker")).unwrap(), "from a");
    }

    #[tokio::test]
    async fn this_process_exists_and_a_dead_pid_does_not() {
        assert!(process_exists(std::process::id()));
        wait_for_exit(u32::MAX - 7, Some(Duration::from_secs(1))).await.unwrap();
        wait_for_exit(u32::MAX - 7, None).await.unwrap();
    }

    #[tokio::test]
    async fn the_wait_ends_when_the_process_quits() {
        #[allow(clippy::disallowed_methods)] // a one-second sleep, reaped below
        let mut child = std::process::Command::new("/bin/sleep").arg("1").spawn().unwrap();
        let pid = child.id();
        let reaper = std::thread::spawn(move || child.wait());
        let started = Instant::now();
        wait_for_exit(pid, None).await.unwrap();
        assert!(started.elapsed() >= Duration::from_millis(500));
        reaper.join().unwrap().unwrap();
        let error = wait_for_exit(std::process::id(), Some(Duration::from_millis(300)))
            .await
            .unwrap_err();
        assert!(error.to_string().contains("still running"), "{error}");
    }

    #[tokio::test]
    async fn a_bundle_with_nothing_running_from_it_is_closed() {
        let dir = tempfile::tempdir().unwrap();
        assert!(wait_for_bundle_to_close(&dir.path().join("Crok Desktop.app"), Duration::from_millis(10)).await);
    }

    #[test]
    fn old_staging_folders_are_swept_and_fresh_ones_kept() {
        let dir = tempfile::tempdir().unwrap();
        let old = dir.path().join(".crok-upgrade-old");
        let fresh = dir.path().join(".crok-upgrade-fresh");
        let other = dir.path().join("Crok Desktop.app");
        for path in [&old, &fresh, &other] {
            std::fs::create_dir(path).unwrap();
        }
        let two_days_ago = std::time::SystemTime::now() - Duration::from_secs(2 * 24 * 60 * 60);
        std::fs::File::open(&old).unwrap().set_modified(two_days_ago).unwrap();
        std::fs::File::open(&other).unwrap().set_modified(two_days_ago).unwrap();
        sweep_stale_staging(dir.path());
        assert!(!old.exists());
        assert!(fresh.exists());
        assert!(other.exists());
    }
}
