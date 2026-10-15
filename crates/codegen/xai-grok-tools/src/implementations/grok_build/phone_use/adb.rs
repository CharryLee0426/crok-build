//! adb: finding it, fetching it, and running it.
//!
//! Crok uses an adb that is already on the machine (`CROK_ADB`, the Android SDK, `PATH`, Homebrew)
//! and otherwise downloads Google's Android SDK Platform-Tools once into `$CROK_HOME/phone`, so an
//! Android phone works with nothing installed by hand.

use std::path::{Path, PathBuf};
use std::time::Duration;

/// Where Google publishes the latest Platform-Tools for each system.
pub const PLATFORM_TOOLS_URL: &str =
    "https://dl.google.com/android/repository/platform-tools-latest-";

/// The adb executable's file name here.
pub const fn adb_file_name() -> &'static str {
    if cfg!(windows) { "adb.exe" } else { "adb" }
}

/// `$CROK_HOME/phone`, where downloaded Platform-Tools live.
pub fn phone_dir() -> PathBuf {
    crate::util::grok_home::grok_home().join("phone")
}

/// The adb Crok downloads, whether or not it is there yet.
pub fn downloaded_adb() -> PathBuf {
    phone_dir().join("platform-tools").join(adb_file_name())
}

/// An adb already on this machine, without downloading anything.
pub fn find_local() -> Option<PathBuf> {
    candidates().into_iter().find(|path| is_executable(path))
}

fn candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    for var in ["CROK_ADB", "GROK_ADB"] {
        if let Some(path) = std::env::var_os(var).filter(|v| !v.is_empty()) {
            out.push(PathBuf::from(path));
        }
    }
    for var in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
        if let Some(root) = std::env::var_os(var).filter(|v| !v.is_empty()) {
            out.push(
                PathBuf::from(root)
                    .join("platform-tools")
                    .join(adb_file_name()),
            );
        }
    }
    if let Ok(path) = which::which(adb_file_name()) {
        out.push(path);
    }
    if cfg!(target_os = "macos") {
        out.push(PathBuf::from("/opt/homebrew/bin/adb"));
        out.push(PathBuf::from("/usr/local/bin/adb"));
    }
    if let Some(home) = xai_dirs::home_dir() {
        if cfg!(target_os = "macos") {
            out.push(home.join("Library/Android/sdk/platform-tools/adb"));
        } else {
            out.push(home.join("Android/Sdk/platform-tools/adb"));
        }
    }
    if cfg!(windows)
        && let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
    {
        out.push(local.join("Android\\Sdk\\platform-tools\\adb.exe"));
    }
    out.push(downloaded_adb());
    out
}

fn is_executable(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

static FETCH: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// An adb to use: one on this machine, or Google's Platform-Tools downloaded once.
pub async fn ensure() -> Result<PathBuf, String> {
    if let Some(path) = find_local() {
        return Ok(path);
    }
    let _one_download = FETCH.lock().await;
    if let Some(path) = find_local() {
        return Ok(path);
    }
    download_into(phone_dir()).await
}

fn platform_name() -> &'static str {
    if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(windows) {
        "windows"
    } else {
        "linux"
    }
}

/// Download Google's Platform-Tools for this system into `dir/platform-tools`.
pub(crate) async fn download_into(dir: PathBuf) -> Result<PathBuf, String> {
    let url = format!("{PLATFORM_TOOLS_URL}{}.zip", platform_name());
    tracing::info!(%url, "downloading Android platform-tools for phone use");
    let client = xai_grok_extra_ca::build_reqwest_client(|builder| {
        builder
            .timeout(Duration::from_secs(300))
            .connect_timeout(Duration::from_secs(15))
    })
    .map_err(|e| format!("could not prepare the adb download: {e}"))?;
    let failed = |e: reqwest::Error| {
        format!(
            "adb is not on this computer and Crok could not download Google's Android platform-tools from {url}: {e}. Check the internet connection, or install adb (for example `brew install android-platform-tools`) and try again."
        )
    };
    let bytes = client
        .get(&url)
        .send()
        .await
        .and_then(reqwest::Response::error_for_status)
        .map_err(failed)?
        .bytes()
        .await
        .map_err(failed)?;
    tokio::task::spawn_blocking(move || unpack(&bytes, &dir))
        .await
        .map_err(|e| e.to_string())?
}

/// Unpack a Platform-Tools archive into `dir/platform-tools`, replacing what was there.
pub(crate) fn unpack(archive: &[u8], dir: &Path) -> Result<PathBuf, String> {
    use std::io::Read as _;
    let failed =
        |e: &dyn std::fmt::Display| format!("could not unpack Android platform-tools: {e}");
    std::fs::create_dir_all(dir).map_err(|e| failed(&e))?;
    let staging = tempfile::Builder::new()
        .prefix(".platform-tools-")
        .tempdir_in(dir)
        .map_err(|e| failed(&e))?;
    let mut zip = zip::ZipArchive::new(std::io::Cursor::new(archive)).map_err(|e| failed(&e))?;
    for i in 0..zip.len() {
        let mut entry = zip.by_index(i).map_err(|e| failed(&e))?;
        let Some(relative) = entry.enclosed_name() else {
            continue;
        };
        let out = staging.path().join(relative);
        if entry.is_dir() {
            std::fs::create_dir_all(&out).map_err(|e| failed(&e))?;
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent).map_err(|e| failed(&e))?;
        }
        let mode = entry.unix_mode();
        #[cfg(unix)]
        if let Some(mode) = mode
            && mode & 0o170_000 == 0o120_000
        {
            let mut target = String::new();
            entry.read_to_string(&mut target).map_err(|e| failed(&e))?;
            std::os::unix::fs::symlink(target.trim(), &out).map_err(|e| failed(&e))?;
            continue;
        }
        let mut file = std::fs::File::create(&out).map_err(|e| failed(&e))?;
        std::io::copy(&mut entry, &mut file).map_err(|e| failed(&e))?;
        #[cfg(unix)]
        if let Some(mode) = mode {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(mode & 0o777));
        }
        #[cfg(not(unix))]
        let _ = mode;
    }
    let unpacked = staging.path().join("platform-tools");
    let adb = unpacked.join(adb_file_name());
    if !adb.is_file() {
        return Err(failed(&"the archive has no platform-tools/adb"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&adb, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| failed(&e))?;
    }
    let target = dir.join("platform-tools");
    if target.exists() {
        std::fs::remove_dir_all(&target).map_err(|e| failed(&e))?;
    }
    std::fs::rename(&unpacked, &target).map_err(|e| failed(&e))?;
    Ok(target.join(adb_file_name()))
}

/// What one adb command printed.
#[derive(Debug, Clone, Default)]
pub struct Output {
    pub stdout: Vec<u8>,
    pub stderr: String,
    pub success: bool,
}

impl Output {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }

    /// stdout and stderr together, as a person reads a failure.
    pub fn message(&self) -> String {
        let out = self.text();
        let joined = format!("{}\n{}", out.trim(), self.stderr.trim());
        joined.trim().to_owned()
    }
}

/// Run `adb [-s serial] args…`, giving up after `timeout`.
pub async fn run(
    adb: &Path,
    serial: Option<&str>,
    args: &[&str],
    timeout: Duration,
) -> Result<Output, String> {
    let mut command = tokio::process::Command::new(adb);
    if let Some(serial) = serial {
        command.args(["-s", serial]);
    }
    command
        .args(args)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let output = tokio::time::timeout(timeout, command.output())
        .await
        .map_err(|_| {
            format!(
                "adb {} did not finish within {} s",
                args.first().copied().unwrap_or(""),
                timeout.as_secs()
            )
        })?
        .map_err(|e| format!("could not run adb ({}): {e}", adb.display()))?;
    Ok(Output {
        stdout: output.stdout,
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        success: output.status.success(),
    })
}

/// How an attached device is reached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Transport {
    Usb,
    Wifi,
}

impl Transport {
    pub fn label(self) -> &'static str {
        match self {
            Self::Usb => "USB",
            Self::Wifi => "Wi‑Fi",
        }
    }
}

/// One row of `adb devices`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attached {
    pub id: String,
    /// `device` when usable; `unauthorized`, `offline`, …
    pub state: String,
    pub transport: Transport,
}

/// The rows of `adb devices`.
pub fn parse_devices(out: &str) -> Vec<Attached> {
    out.lines()
        .filter(|line| !line.starts_with("List of devices") && !line.starts_with('*'))
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let id = fields.next()?;
            let state = fields.next()?;
            let transport = if id.contains(':') || id.starts_with("adb-") {
                Transport::Wifi
            } else {
                Transport::Usb
            };
            Some(Attached {
                id: id.to_owned(),
                state: state.to_owned(),
                transport,
            })
        })
        .collect()
}

/// A phone announcing itself on the network.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Service {
    /// The hardware serial in the service name (`adb-<serial>-<suffix>`).
    pub serial: String,
    pub host: String,
    /// `host:port`.
    pub address: String,
}

/// The `_adb-tls-<kind>` services of `adb mdns services`: `connect` for paired phones with
/// Wireless debugging on, `pairing` for a phone showing its pairing-code dialog.
pub fn parse_mdns(out: &str, kind: &str) -> Vec<Service> {
    let wanted = format!("_adb-tls-{kind}");
    out.lines()
        .filter_map(|line| {
            let parts: Vec<&str> = if line.contains('\t') {
                line.split('\t').map(str::trim).collect()
            } else {
                line.split_whitespace().collect()
            };
            let (name, service, address) = (parts.first()?, parts.get(1)?, parts.get(2)?);
            if !service.contains(&wanted) {
                return None;
            }
            let serial = name
                .strip_prefix("adb-")
                .and_then(|rest| rest.rsplit_once('-'))
                .map(|(serial, _)| serial)?;
            let (host, port) = address.rsplit_once(':')?;
            if host.is_empty() || port.parse::<u16>().is_err() {
                return None;
            }
            Some(Service {
                serial: serial.to_owned(),
                host: host.to_owned(),
                address: (*address).to_owned(),
            })
        })
        .collect()
}

/// `text` quoted for the phone's shell, inside single quotes.
pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn devices_are_read_with_their_transport() {
        let out = "* daemon started successfully\nList of devices attached\nR5CT123\tdevice\n192.168.1.5:41234\tdevice\nadb-R5CT9-xYz._adb-tls-connect._tcp\toffline\nZX1\tunauthorized\n\n";
        let rows = parse_devices(out);
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].transport, Transport::Usb);
        assert_eq!(rows[1].transport, Transport::Wifi);
        assert_eq!(rows[2].state, "offline");
        assert_eq!(rows[2].transport, Transport::Wifi);
        assert_eq!(rows[3].state, "unauthorized");
    }

    #[test]
    fn mdns_services_carry_serial_and_address() {
        let out = "List of discovered mdns services\nadb-R5CT123-AbCdEf\t_adb-tls-connect._tcp\t192.168.1.23:41234\nadb-R5CT123-AbCdEf\t_adb-tls-pairing._tcp\t192.168.1.23:37011\nnonsense line\n";
        let connect = parse_mdns(out, "connect");
        assert_eq!(
            connect,
            vec![Service {
                serial: "R5CT123".into(),
                host: "192.168.1.23".into(),
                address: "192.168.1.23:41234".into(),
            }]
        );
        assert_eq!(parse_mdns(out, "pairing")[0].address, "192.168.1.23:37011");
    }

    #[test]
    fn quoting_survives_single_quotes() {
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
    }

    #[test]
    fn unpacks_platform_tools_and_replaces_an_old_copy() {
        use std::io::Write as _;
        let mut buffer = std::io::Cursor::new(Vec::new());
        {
            let mut writer = zip::ZipWriter::new(&mut buffer);
            let options = zip::write::SimpleFileOptions::default().unix_permissions(0o755);
            writer.add_directory("platform-tools/", options).unwrap();
            writer
                .start_file(format!("platform-tools/{}", adb_file_name()), options)
                .unwrap();
            writer.write_all(b"#!/bin/sh\necho adb\n").unwrap();
            writer.start_file("../escape", options).unwrap();
            writer.write_all(b"no").unwrap();
            writer.finish().unwrap();
        }
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("platform-tools")).unwrap();
        std::fs::write(dir.path().join("platform-tools/stale"), b"old").unwrap();
        let adb = unpack(buffer.get_ref(), dir.path()).unwrap();
        assert!(adb.is_file());
        assert!(is_executable(&adb));
        assert!(!dir.path().join("platform-tools/stale").exists());
        assert!(!dir.path().parent().unwrap().join("escape").exists());
    }
}
