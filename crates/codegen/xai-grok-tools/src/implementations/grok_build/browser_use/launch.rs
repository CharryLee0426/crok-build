//! Finding a Chromium-based browser and reaching its DevTools endpoint, in one of two ways.
//!
//! The user's own browser ([`connect_user_browser`], the default). Since Chrome 136
//! `--remote-debugging-port` does nothing on the default user data folder, so Crok never starts a
//! debugging server there. It reaches the one the browser starts itself once the user turns on
//! "Allow remote debugging for this browser instance" at chrome://inspect/#remote-debugging
//! (Chrome 144 and later; the switch is kept in Local State, so it stays on). That server listens
//! on 9222 when the port is free, writes `DevToolsActivePort` to the user data folder, accepts any
//! path under `/devtools/browser`, and holds each new connection until the user answers the
//! browser's "Allow remote debugging?" dialog.
//!
//! A profile of Crok's own ([`connect_or_launch`], `$CROK_HOME/browser/profile` by default),
//! never the user's everyday profile, started with `--remote-debugging-port=0`. Chrome writes the
//! port it chose to `DevToolsActivePort` in the profile, so every Crok session that needs the
//! browser reads that file and connects to the one instance, each with tabs of its own. The browser
//! is started detached, outlives the session that started it, and is quit by the last session that
//! leaves it with no tabs.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use super::cdp::{CdpConnection, CdpError};

/// The viewport size a window Crok opens starts with.
pub const WINDOW_WIDTH: u32 = 1280;
pub const WINDOW_HEIGHT: u32 = 900;
const PORT_FILE: &str = "DevToolsActivePort";
const START_TIMEOUT: Duration = Duration::from_secs(20);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
/// How long the user's browser may wait for the user to answer "Allow remote debugging?".
pub const APPROVAL_TIMEOUT: Duration = Duration::from_secs(120);
/// A refusal this quick came from the browser, not from a person: it had no window to ask in.
const INSTANT_REFUSAL: Duration = Duration::from_millis(1500);
/// The port the browser's own debugging server takes when it is free.
const DEFAULT_DEBUGGING_PORT: u16 = 9222;
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);
/// What the browser's own debugging server accepts in place of the browser's id.
const BROWSER_PATH: &str = "/devtools/browser";

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
    let (port, path) = parse_port_file(contents)?;
    Some(format!("ws://127.0.0.1:{port}{path}"))
}

fn parse_port_file(contents: &str) -> Option<(u16, String)> {
    let mut lines = contents.lines();
    let port: u16 = lines.next()?.trim().parse().ok()?;
    let path = lines.next()?.trim();
    if port == 0 || !path.starts_with('/') {
        return None;
    }
    Some((port, path.to_owned()))
}

/// Where a debugging server listens.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Endpoint {
    /// `127.0.0.1:9222`, or `[::1]:9222`.
    address: String,
    path: String,
}

impl Endpoint {
    fn new(address: String) -> Self {
        Self {
            address,
            path: BROWSER_PATH.to_owned(),
        }
    }

    fn url(&self) -> String {
        format!("ws://{}{}", self.address, self.path)
    }
}

/// How the user's browser answered a connection.
#[derive(Debug, PartialEq, Eq)]
enum Answer {
    /// Refused sooner than a person could have answered.
    RefusedAtOnce,
    Refused,
    Unanswered,
    Failed(String),
}

impl Answer {
    fn message(&self, name: &str) -> String {
        match self {
            Self::RefusedAtOnce => format!(
                "{name} refused the connection without asking: it asks in one of its windows, and none is open. Open a {name} window, then try again."
            ),
            Self::Refused => format!(
                "{name} refused the connection: its \"Allow remote debugging?\" dialog was closed or answered with Cancel. Try again and click Allow in {name}."
            ),
            Self::Unanswered => format!(
                "No one answered {name}'s \"Allow remote debugging?\" dialog within {} s. Try again and click Allow in {name}.",
                APPROVAL_TIMEOUT.as_secs()
            ),
            Self::Failed(error) => format!("Could not connect to {name}: {error}"),
        }
    }
}

/// Connect to the browser the user runs every day, on the profile they used last, and start it
/// first when it is not running. `user_data_dir` names its user data folder when that is not the
/// browser's default one.
pub async fn connect_user_browser(
    executable: Option<&Path>,
    user_data_dir: Option<&Path>,
) -> Result<Connected, String> {
    let executable = find_executable(executable)?;
    let name = browser_name(&executable);
    let mut launched = false;
    let mut endpoints = reachable(user_endpoints(&executable, user_data_dir)).await;
    if endpoints.is_empty() {
        // Running with nothing listening means remote debugging is off; starting it again would
        // only open a window
        if user_data_dir.is_none() && running_pids(&executable).is_some_and(|pids| !pids.is_empty())
        {
            return Err(not_allowed(&name, false));
        }
        open_user_browser(&executable, user_data_dir)?;
        launched = true;
        let deadline = tokio::time::Instant::now() + START_TIMEOUT;
        while endpoints.is_empty() && tokio::time::Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(250)).await;
            endpoints = reachable(user_endpoints(&executable, user_data_dir)).await;
        }
        if endpoints.is_empty() {
            return Err(not_allowed(&name, true));
        }
    }
    let connection = match ask(&endpoints).await {
        // The browser asks in its last active window; with no window open it refuses at once
        Err(Answer::RefusedAtOnce) => {
            open_user_browser(&executable, user_data_dir)?;
            tokio::time::sleep(Duration::from_secs(1)).await;
            ask(&endpoints).await
        }
        other => other,
    }
    .map_err(|answer| answer.message(&name))?;
    Ok(Connected {
        connection,
        launched,
    })
}

fn not_allowed(name: &str, started: bool) -> String {
    let state = if started { "started" } else { "is running" };
    format!(
        "{name} {state}, but it does not let Crok connect. Once, in {name}: open chrome://inspect/#remote-debugging and turn on \"Allow remote debugging for this browser instance\" (Chrome 144 or later). Then try again, and click Allow when {name} asks. To use a browser with a profile of Crok's own instead, set [toolset.browser] profile = \"crok\" in config.toml."
    )
}

/// Open the first endpoint that is the browser's own server, which asks the user first.
async fn ask(endpoints: &[Endpoint]) -> Result<Arc<CdpConnection>, Answer> {
    let mut failure = Answer::Failed("nothing answered".to_owned());
    for endpoint in endpoints {
        let started = tokio::time::Instant::now();
        let attempt = tokio::time::timeout(
            APPROVAL_TIMEOUT,
            CdpConnection::connect(&endpoint.url(), APPROVAL_TIMEOUT + CONNECT_TIMEOUT),
        )
        .await;
        match attempt {
            Ok(Ok(connection)) => return Ok(connection),
            Err(_) => return Err(Answer::Unanswered),
            // Another program's debugging server, which wants its own browser's id
            Ok(Err(CdpError::Rejected(404))) => {
                failure = Answer::Failed(format!(
                    "the debugging server at {} is not the browser's own",
                    endpoint.address
                ));
            }
            Ok(Err(CdpError::Rejected(_))) if started.elapsed() < INSTANT_REFUSAL => {
                return Err(Answer::RefusedAtOnce);
            }
            Ok(Err(CdpError::Rejected(_))) => return Err(Answer::Refused),
            Ok(Err(error)) => failure = Answer::Failed(error.to_string()),
        }
    }
    Err(failure)
}

/// The endpoints something listens on.
async fn reachable(endpoints: Vec<Endpoint>) -> Vec<Endpoint> {
    let mut open = Vec::new();
    for endpoint in endpoints {
        if let Ok(Ok(_)) = tokio::time::timeout(
            PROBE_TIMEOUT,
            tokio::net::TcpStream::connect(endpoint.address.as_str()),
        )
        .await
        {
            open.push(endpoint);
        }
    }
    open
}

/// Where the user's browser may be listening, most certain first.
fn user_endpoints(executable: &Path, user_data_dir: Option<&Path>) -> Vec<Endpoint> {
    // A folder named in config.toml is the one to read: other copies of the browser are not that one
    if let Some(dir) = user_data_dir {
        return port_file_endpoint(dir).into_iter().collect();
    }
    let mut endpoints = Vec::new();
    // Ask the system what the browser listens on: macOS keeps other apps' folders, the port file
    // among them, from Crok (and may ask the user about it). Without `lsof`, read the port file
    // where that is allowed, then try the usual port.
    #[cfg(unix)]
    let listening = running_pids(executable).and_then(|pids| listening_addresses(&pids));
    #[cfg(not(unix))]
    let listening: Option<Vec<String>> = None;
    match listening {
        Some(addresses) => endpoints.extend(addresses.into_iter().map(Endpoint::new)),
        None => {
            if !cfg!(target_os = "macos")
                && let Some(dir) = default_user_data_dir(executable)
            {
                endpoints.extend(port_file_endpoint(&dir));
            }
            endpoints.push(Endpoint::new(format!("127.0.0.1:{DEFAULT_DEBUGGING_PORT}")));
        }
    }
    let mut seen = HashSet::new();
    endpoints.retain(|endpoint| seen.insert(endpoint.address.clone()));
    endpoints
}

fn port_file_endpoint(dir: &Path) -> Option<Endpoint> {
    let contents = std::fs::read_to_string(dir.join(PORT_FILE)).ok()?;
    let (port, path) = parse_port_file(&contents)?;
    Some(Endpoint {
        address: format!("127.0.0.1:{port}"),
        path,
    })
}

/// The browser's name as its menus say it: "Google Chrome", "Microsoft Edge".
pub fn browser_name(executable: &Path) -> String {
    if let Some(bundle) = app_bundle(executable)
        && let Some(stem) = bundle.file_stem()
    {
        return stem.to_string_lossy().into_owned();
    }
    let stem = executable
        .file_stem()
        .map(|s| s.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let known = [
        ("chromium", "Chromium"),
        ("chrome", "Google Chrome"),
        ("msedge", "Microsoft Edge"),
        ("microsoft-edge", "Microsoft Edge"),
        ("brave", "Brave"),
    ];
    known
        .iter()
        .find(|(prefix, _)| {
            stem.starts_with(prefix) || stem.starts_with(&format!("google-{prefix}"))
        })
        .map(|(_, name)| (*name).to_owned())
        .unwrap_or_else(|| "The browser".to_owned())
}

/// The `.app` bundle an executable on macOS belongs to.
fn app_bundle(executable: &Path) -> Option<&Path> {
    executable
        .ancestors()
        .find(|path| path.extension().is_some_and(|extension| extension == "app"))
}

/// Where the browser keeps its user data when it is started with no `--user-data-dir`.
#[cfg(all(unix, not(target_os = "macos")))]
fn default_user_data_dir(executable: &Path) -> Option<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|dir| dir.is_absolute())
        .or_else(|| xai_dirs::home_dir().map(|home| home.join(".config")))?;
    linux_user_data_dir(executable, &config)
}

#[cfg(windows)]
fn default_user_data_dir(executable: &Path) -> Option<PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from)?;
    windows_user_data_dir(executable, &local)
}

#[cfg(target_os = "macos")]
fn default_user_data_dir(_executable: &Path) -> Option<PathBuf> {
    None
}

#[cfg(any(test, all(unix, not(target_os = "macos"))))]
fn linux_user_data_dir(executable: &Path, config: &Path) -> Option<PathBuf> {
    let name = executable.file_name()?.to_str()?;
    let folder = match name {
        "google-chrome" | "google-chrome-stable" => "google-chrome",
        "google-chrome-beta" => "google-chrome-beta",
        "google-chrome-unstable" => "google-chrome-unstable",
        "chromium" | "chromium-browser" => "chromium",
        "microsoft-edge" | "microsoft-edge-stable" => "microsoft-edge",
        "microsoft-edge-beta" => "microsoft-edge-beta",
        "microsoft-edge-dev" => "microsoft-edge-dev",
        "brave-browser" | "brave-browser-stable" => "BraveSoftware/Brave-Browser",
        _ => return None,
    };
    Some(config.join(folder))
}

#[cfg(any(test, windows))]
fn windows_user_data_dir(executable: &Path, local_app_data: &Path) -> Option<PathBuf> {
    let parts: Vec<String> = executable
        .components()
        .map(|part| part.as_os_str().to_string_lossy().to_lowercase())
        .collect();
    let folder = parts.windows(2).find_map(|pair| {
        match (pair.first()?.as_str(), pair.get(1)?.as_str()) {
            ("google", "chrome sxs") => Some("Google/Chrome SxS"),
            ("google", "chrome") => Some("Google/Chrome"),
            ("microsoft", "edge") => Some("Microsoft/Edge"),
            ("bravesoftware", "brave-browser") => Some("BraveSoftware/Brave-Browser"),
            _ => None,
        }
    })?;
    Some(local_app_data.join(folder).join("User Data"))
}

/// The processes running `executable`; `None` where Crok cannot tell.
#[cfg(target_os = "macos")]
fn running_pids(executable: &Path) -> Option<Vec<u32>> {
    // `comm` is the executable's full path; a browser's helpers live elsewhere in its bundle
    let output = std::process::Command::new("/bin/ps")
        .args(["-axo", "pid=,comm="])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let wanted = dunce::canonicalize(executable).unwrap_or_else(|_| executable.to_path_buf());
    let file_name = wanted.file_name()?;
    Some(
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| {
                let (pid, path) = line.trim_start().split_once(' ')?;
                let path = Path::new(path.trim());
                (path.file_name() == Some(file_name)
                    && (path == wanted || dunce::canonicalize(path).is_ok_and(|p| p == wanted)))
                .then(|| pid.parse().ok())
                .flatten()
            })
            .collect(),
    )
}

#[cfg(all(unix, not(target_os = "macos")))]
fn running_pids(executable: &Path) -> Option<Vec<u32>> {
    // Launchers such as /usr/bin/google-chrome are scripts that start a binary next to them
    let wanted = dunce::canonicalize(executable).ok()?;
    let folder = wanted.parent()?.to_path_buf();
    let entries = std::fs::read_dir("/proc").ok()?;
    Some(
        entries
            .filter_map(Result::ok)
            .filter_map(|entry| {
                let pid: u32 = entry.file_name().to_str()?.parse().ok()?;
                let exe = std::fs::read_link(entry.path().join("exe")).ok()?;
                (exe.parent() == Some(folder.as_path())).then_some(pid)
            })
            .collect(),
    )
}

#[cfg(windows)]
fn running_pids(_executable: &Path) -> Option<Vec<u32>> {
    None
}

/// The loopback TCP addresses these processes listen on; `None` when `lsof` cannot be run.
#[cfg(unix)]
fn listening_addresses(pids: &[u32]) -> Option<Vec<String>> {
    if pids.is_empty() {
        return Some(Vec::new());
    }
    let lsof = ["/usr/sbin/lsof", "/usr/bin/lsof", "/bin/lsof"]
        .into_iter()
        .map(Path::new)
        .find(|path| path.is_file())?;
    let list = pids
        .iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(",");
    // `lsof` exits 1 when nothing matched, which is an answer too
    let output = std::process::Command::new(lsof)
        .args(["-nP", "-a", "-p", &list, "-iTCP", "-sTCP:LISTEN", "-Fn"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    Some(parse_lsof_listening(&String::from_utf8_lossy(
        &output.stdout,
    )))
}

/// Loopback addresses from `lsof -Fn` lines such as `n127.0.0.1:9222`, `n[::1]:9222`, `n*:9222`.
#[cfg(any(test, unix))]
fn parse_lsof_listening(output: &str) -> Vec<String> {
    output
        .lines()
        .filter_map(|line| line.strip_prefix('n'))
        .filter_map(|name| {
            let (host, port) = name.rsplit_once(':')?;
            let port: u16 = port.parse().ok()?;
            let host = match host {
                "127.0.0.1" | "localhost" | "*" => "127.0.0.1",
                "[::1]" => "[::1]",
                _ => return None,
            };
            Some(format!("{host}:{port}"))
        })
        .collect()
}

/// Start the user's browser as they would, or have it open a window.
fn open_user_browser(executable: &Path, user_data_dir: Option<&Path>) -> Result<(), String> {
    if let Some(dir) = user_data_dir {
        return spawn_detached(executable, &[format!("--user-data-dir={}", dir.display())]);
    }
    #[cfg(target_os = "macos")]
    if let Some(bundle) = app_bundle(executable) {
        // Through Launch Services, as the Dock does: the browser is nobody's child, it opens a
        // window when it has none, and macOS asks about the camera for the browser, not for Crok
        let status = std::process::Command::new("/usr/bin/open")
            .arg("-a")
            .arg(bundle)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map_err(|e| format!("could not open {}: {e}", bundle.display()))?;
        return if status.success() {
            Ok(())
        } else {
            Err(format!(
                "could not open {}: open exited with {status}",
                bundle.display()
            ))
        };
    }
    spawn_detached(executable, &[])
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

    #[test]
    fn browsers_are_named_as_their_menus_say() {
        let mac =
            Path::new("/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta");
        assert_eq!(browser_name(mac), "Google Chrome Beta");
        assert_eq!(
            browser_name(Path::new("/usr/bin/google-chrome-stable")),
            "Google Chrome"
        );
        assert_eq!(
            browser_name(Path::new("/usr/bin/chromium-browser")),
            "Chromium"
        );
        assert_eq!(
            browser_name(Path::new(
                "C:/Program Files/Microsoft/Edge/Application/msedge.exe"
            )),
            "Microsoft Edge"
        );
        assert_eq!(browser_name(Path::new("/usr/bin/brave-browser")), "Brave");
        assert_eq!(browser_name(Path::new("/opt/odd/thing")), "The browser");
    }

    #[test]
    fn default_user_data_folders_follow_each_browser() {
        let config = Path::new("/home/me/.config");
        assert_eq!(
            linux_user_data_dir(Path::new("/usr/bin/google-chrome"), config),
            Some(config.join("google-chrome"))
        );
        assert_eq!(
            linux_user_data_dir(Path::new("/usr/bin/brave-browser"), config),
            Some(config.join("BraveSoftware/Brave-Browser"))
        );
        assert_eq!(
            linux_user_data_dir(Path::new("/usr/bin/firefox"), config),
            None
        );
        let local = Path::new("C:/Users/me/AppData/Local");
        assert_eq!(
            windows_user_data_dir(
                Path::new("C:/Program Files/Google/Chrome/Application/chrome.exe"),
                local
            ),
            Some(local.join("Google/Chrome").join("User Data"))
        );
        assert_eq!(
            windows_user_data_dir(
                Path::new("C:/Users/me/AppData/Local/Google/Chrome SxS/Application/chrome.exe"),
                local
            ),
            Some(local.join("Google/Chrome SxS").join("User Data"))
        );
        assert_eq!(
            windows_user_data_dir(
                Path::new("C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"),
                local
            ),
            Some(local.join("Microsoft/Edge").join("User Data"))
        );
    }

    #[test]
    fn lsof_listeners_keep_only_loopback() {
        let output = "p48322\nf87\nn127.0.0.1:9222\nf88\nn[::1]:9222\nf89\nn*:51000\nf90\nn192.168.1.4:7000\n";
        assert_eq!(
            parse_lsof_listening(output),
            vec!["127.0.0.1:9222", "[::1]:9222", "127.0.0.1:51000"]
        );
    }

    #[test]
    fn a_named_user_data_folder_is_the_only_place_looked_at() {
        let dir = tempfile::tempdir().unwrap();
        let chrome = Path::new("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome");
        assert!(user_endpoints(chrome, Some(dir.path())).is_empty());
        std::fs::write(dir.path().join(PORT_FILE), "9333\n/devtools/browser/abc").unwrap();
        assert_eq!(
            user_endpoints(chrome, Some(dir.path())),
            vec![Endpoint {
                address: "127.0.0.1:9333".to_owned(),
                path: "/devtools/browser/abc".to_owned()
            }]
        );
    }

    #[test]
    fn refusals_say_what_to_do() {
        assert!(
            Answer::Refused
                .message("Google Chrome")
                .contains("click Allow in Google Chrome")
        );
        assert!(
            Answer::RefusedAtOnce
                .message("Google Chrome")
                .contains("Open a Google Chrome window")
        );
        assert!(Answer::Unanswered.message("Brave").contains("within 120 s"));
        let off = not_allowed("Google Chrome", false);
        assert!(off.contains("chrome://inspect/#remote-debugging"), "{off}");
        assert!(off.contains("profile = \"crok\""), "{off}");
    }

    /// A server that answers every WebSocket handshake with `status`, as a browser that refuses does.
    async fn refusing_server(status: u16, delay: Duration) -> String {
        use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap().to_string();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::time::sleep(delay).await;
                let _ = tokio_tungstenite::accept_hdr_async(
                    stream,
                    move |_: &Request, _: Response| -> Result<Response, ErrorResponse> {
                        let mut refusal =
                            ErrorResponse::new(Some("Connection rejected".to_owned()));
                        *refusal.status_mut() =
                            tokio_tungstenite::tungstenite::http::StatusCode::from_u16(status)
                                .unwrap();
                        Err(refusal)
                    },
                )
                .await;
            }
        });
        address
    }

    #[tokio::test]
    async fn a_refusal_is_told_apart_from_another_programs_server() {
        let refusing = refusing_server(403, Duration::ZERO).await;
        assert_eq!(
            ask(&[Endpoint::new(refusing.clone())]).await.err(),
            Some(Answer::RefusedAtOnce)
        );
        let slow = refusing_server(403, INSTANT_REFUSAL + Duration::from_millis(100)).await;
        assert_eq!(
            ask(&[Endpoint::new(slow)]).await.err(),
            Some(Answer::Refused)
        );
        // A server that wants its browser's id is skipped for the next one
        let other = refusing_server(404, Duration::ZERO).await;
        assert_eq!(
            ask(&[Endpoint::new(other.clone()), Endpoint::new(refusing)])
                .await
                .err(),
            Some(Answer::RefusedAtOnce)
        );
        assert!(matches!(
            ask(&[Endpoint::new(other)]).await.err(),
            Some(Answer::Failed(message)) if message.contains("is not the browser's own")
        ));
    }

    #[tokio::test]
    async fn only_listening_endpoints_are_reachable() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let open = listener.local_addr().unwrap().to_string();
        let closed = {
            let gone = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            gone.local_addr().unwrap().to_string()
        };
        let found = reachable(vec![Endpoint::new(closed), Endpoint::new(open.clone())]).await;
        assert_eq!(found, vec![Endpoint::new(open)]);
    }
}
