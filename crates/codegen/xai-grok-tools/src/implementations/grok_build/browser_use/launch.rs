//! Finding a Chromium-based browser and reaching its DevTools endpoint.
//!
//! The browser runs with a profile of its own (`$CROK_HOME/browser/profile` by default), never
//! the user's everyday profile, and with `--remote-debugging-port=0`. Chrome writes the port it
//! chose to `DevToolsActivePort` in the profile, so every Crok session that needs the browser
//! reads that file and connects to the one instance, each with tabs of its own. The browser is
//! started detached, outlives the session that started it, and is quit by the last session that
//! leaves it with no tabs.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use super::cdp::CdpConnection;

/// The viewport size a window Crok opens starts with.
pub const WINDOW_WIDTH: u32 = 1280;
pub const WINDOW_HEIGHT: u32 = 900;
const PORT_FILE: &str = "DevToolsActivePort";
const START_TIMEOUT: Duration = Duration::from_secs(20);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// A connection, and whether this call started the browser.
pub struct Connected {
    pub connection: Arc<CdpConnection>,
    pub launched: bool,
}

/// The profile directory, created owner-only if it is missing.
pub fn profile_dir(configured: Option<&Path>) -> Result<PathBuf, String> {
    let dir = configured
        .map(Path::to_path_buf)
        .unwrap_or_else(default_profile_dir);
    create_private_dir(&dir)?;
    Ok(dir)
}

pub fn default_profile_dir() -> PathBuf {
    crate::util::grok_home::grok_home()
        .join("browser")
        .join("profile")
}

pub fn default_download_dir() -> PathBuf {
    crate::util::grok_home::grok_home()
        .join("browser")
        .join("downloads")
}

pub fn create_private_dir(dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| format!("could not create {}: {e}", dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    Ok(())
}

/// Connect to the browser already running on `profile`, or start `executable` on it.
pub async fn connect_or_launch(
    profile: &Path,
    executable: Option<&Path>,
    headless: bool,
) -> Result<Connected, String> {
    if let Some(url) = read_endpoint(profile)
        && let Ok(connection) = CdpConnection::connect(&url, CONNECT_TIMEOUT).await
    {
        return Ok(Connected {
            connection,
            launched: false,
        });
    }
    let executable = find_executable(executable)?;
    // A port file left by a browser that has since quit would only be read back
    let _ = std::fs::remove_file(profile.join(PORT_FILE));
    spawn_detached(&executable, &launch_args(profile, headless))?;
    let deadline = tokio::time::Instant::now() + START_TIMEOUT;
    while tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(150)).await;
        if let Some(url) = read_endpoint(profile)
            && let Ok(connection) = CdpConnection::connect(&url, CONNECT_TIMEOUT).await
        {
            return Ok(Connected {
                connection,
                launched: true,
            });
        }
    }
    Err(format!(
        "{} started but did not open its DevTools port within {} s. Quit any copy of it that uses the profile {} and try again.",
        executable.display(),
        START_TIMEOUT.as_secs(),
        profile.display()
    ))
}

pub fn launch_args(profile: &Path, headless: bool) -> Vec<String> {
    let mut args = vec![
        format!("--user-data-dir={}", profile.display()),
        "--remote-debugging-port=0".to_owned(),
        "--no-first-run".to_owned(),
        "--no-default-browser-check".to_owned(),
        "--disable-search-engine-choice-screen".to_owned(),
        "--disable-features=Translate".to_owned(),
        format!("--window-size={WINDOW_WIDTH},{WINDOW_HEIGHT}"),
    ];
    if headless {
        args.push("--headless=new".to_owned());
    }
    args.push("about:blank".to_owned());
    args
}

/// The `ws://` URL in a profile's `DevToolsActivePort`: the port, then the browser target's path.
pub fn read_endpoint(profile: &Path) -> Option<String> {
    let contents = std::fs::read_to_string(profile.join(PORT_FILE)).ok()?;
    parse_endpoint(&contents)
}

fn parse_endpoint(contents: &str) -> Option<String> {
    let mut lines = contents.lines();
    let port: u16 = lines.next()?.trim().parse().ok()?;
    let path = lines.next()?.trim();
    if port == 0 || !path.starts_with('/') {
        return None;
    }
    Some(format!("ws://127.0.0.1:{port}{path}"))
}

/// The configured browser, or the first Chromium-based browser installed in a usual place.
pub fn find_executable(configured: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(path) = configured {
        return if path.is_file() {
            Ok(path.to_path_buf())
        } else {
            Err(format!(
                "The browser set in [toolset.browser] executable, {}, does not exist.",
                path.display()
            ))
        };
    }
    if let Some(path) = std::env::var_os("CROK_BROWSER_EXECUTABLE").map(PathBuf::from)
        && path.is_file()
    {
        return Ok(path);
    }
    candidates()
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| {
            "No Chromium-based browser was found. Install Google Chrome, Chromium, Microsoft Edge or Brave, or set [toolset.browser] executable in config.toml.".to_owned()
        })
}

#[cfg(target_os = "macos")]
fn candidates() -> Vec<PathBuf> {
    let apps = [
        "Google Chrome.app/Contents/MacOS/Google Chrome",
        "Chromium.app/Contents/MacOS/Chromium",
        "Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "Brave Browser.app/Contents/MacOS/Brave Browser",
        "Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
        "Google Chrome Dev.app/Contents/MacOS/Google Chrome Dev",
        "Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
    ];
    let mut roots = vec![PathBuf::from("/Applications")];
    if let Some(home) = dirs_home() {
        roots.push(home.join("Applications"));
    }
    roots
        .iter()
        .flat_map(|root| apps.iter().map(move |app| root.join(app)))
        .collect()
}

#[cfg(all(unix, not(target_os = "macos")))]
fn candidates() -> Vec<PathBuf> {
    [
        "google-chrome",
        "google-chrome-stable",
        "chromium",
        "chromium-browser",
        "microsoft-edge",
        "microsoft-edge-stable",
        "brave-browser",
    ]
    .iter()
    .filter_map(|name| which::which(name).ok())
    .collect()
}

#[cfg(windows)]
fn candidates() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    for var in ["PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA"] {
        if let Some(root) = std::env::var_os(var).map(PathBuf::from) {
            paths.push(root.join("Google/Chrome/Application/chrome.exe"));
            paths.push(root.join("Microsoft/Edge/Application/msedge.exe"));
            paths.push(root.join("BraveSoftware/Brave-Browser/Application/brave.exe"));
        }
    }
    paths
}

#[cfg(target_os = "macos")]
fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Start the browser in a process group of its own, so the terminal's Ctrl+C never reaches it.
fn spawn_detached(executable: &Path, args: &[String]) -> Result<(), String> {
    let mut command = std::process::Command::new(executable);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    #[allow(clippy::disallowed_methods)]
    // every session on this profile shares the browser, so it outlives the one that started it
    let mut child = command
        .spawn()
        .map_err(|e| format!("could not start {}: {e}", executable.display()))?;
    // Reaped here while this process lives; after that the system adopts it
    std::thread::Builder::new()
        .name("crok-browser-reaper".to_owned())
        .spawn(move || {
            let _ = child.wait();
        })
        .map_err(|e| format!("could not watch the browser process: {e}"))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_file_parses_port_and_path() {
        assert_eq!(
            parse_endpoint("9222\n/devtools/browser/abc-123\n").as_deref(),
            Some("ws://127.0.0.1:9222/devtools/browser/abc-123")
        );
        assert_eq!(parse_endpoint("0\n/devtools/browser/x"), None);
        assert_eq!(parse_endpoint("9222\n"), None);
        assert_eq!(parse_endpoint("nope\n/x"), None);
    }

    #[test]
    fn launch_uses_its_own_profile_and_a_random_port() {
        let args = launch_args(Path::new("/tmp/p"), true);
        assert!(args.contains(&"--user-data-dir=/tmp/p".to_owned()));
        assert!(args.contains(&"--remote-debugging-port=0".to_owned()));
        assert!(args.contains(&"--headless=new".to_owned()));
        assert_eq!(args.last().map(String::as_str), Some("about:blank"));
        assert!(!launch_args(Path::new("/tmp/p"), false).contains(&"--headless=new".to_owned()));
    }

    #[test]
    fn a_configured_browser_must_exist() {
        let err = find_executable(Some(Path::new("/definitely/not/here"))).unwrap_err();
        assert!(err.contains("does not exist"));
    }
}
