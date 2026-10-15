//! Device sign-in (RFC 8628 style): get a code, let a person approve it on the web or from the phone app, poll until
//! approved, keep the refresh token.

use std::time::Duration;

use anyhow::Context;

use crate::api::{Api, LoginPoll, LoginStart};
use crate::credentials::{self, Credentials};

#[derive(Clone, Debug)]
pub struct LoginRequest {
    pub server: String,
    pub device_name: String,
    pub platform: String,
    pub client: String,
}

/// Why a sign-in did not finish.
#[derive(Debug)]
pub enum LoginError {
    Denied,
    Expired,
    Other(anyhow::Error),
}

impl std::fmt::Display for LoginError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LoginError::Denied => f.write_str(xai_grok_i18n::tl("The sign-in was denied.")),
            LoginError::Expired => f.write_str(xai_grok_i18n::tl(
                "The code expired before it was approved. Run the sign-in again.",
            )),
            LoginError::Other(error) => write!(f, "{error:#}"),
        }
    }
}

impl std::error::Error for LoginError {}

impl From<anyhow::Error> for LoginError {
    fn from(error: anyhow::Error) -> Self {
        LoginError::Other(error)
    }
}

/// Starts a sign-in and returns the code to show. Call [`wait`] with it next.
pub async fn begin(api: &Api, request: &LoginRequest) -> Result<LoginStart, LoginError> {
    api.start_login(&request.device_name, &request.platform, &request.client)
        .await
        .map_err(|e| {
            LoginError::Other(anyhow::Error::new(e).context("could not start the sign-in"))
        })
}

/// Polls until the code is approved, denied or expires, then saves and returns the credentials.
pub async fn wait(
    api: &Api,
    request: &LoginRequest,
    start: &LoginStart,
) -> Result<Credentials, LoginError> {
    let interval = Duration::from_secs_f64(start.interval.clamp(1.0, 10.0));
    let mut transient_failures = 0u32;
    loop {
        tokio::time::sleep(interval).await;
        let poll = match api.poll_login(&start.device_code).await {
            Ok(poll) => poll,
            // A dropped connection while waiting is retried; the code stays valid for minutes.
            Err(crate::api::ApiError::Transport(message)) if transient_failures < 30 => {
                transient_failures += 1;
                tracing::debug!(%message, "remote sign-in poll failed; retrying");
                continue;
            }
            Err(error) => return Err(LoginError::Other(anyhow::Error::new(error))),
        };
        transient_failures = 0;
        match poll {
            LoginPoll::Pending => {
                if crate::types::now_ms() > start.expires_at + 5_000.0 {
                    return Err(LoginError::Expired);
                }
            }
            LoginPoll::Denied => return Err(LoginError::Denied),
            LoginPoll::Expired => return Err(LoginError::Expired),
            LoginPoll::Approved {
                device_id,
                refresh_token,
                account,
                ..
            } => {
                let credentials = Credentials {
                    server: request.server.clone(),
                    device_id,
                    refresh_token,
                    device_name: request.device_name.clone(),
                    account,
                    linked_at: chrono::Utc::now().timestamp_millis(),
                };
                credentials::save(&credentials).context("saving the remote credentials")?;
                return Ok(credentials);
            }
        }
    }
}

/// Whether a browser can be opened here: not over SSH, and not without a display on Linux.
pub fn can_open_browser() -> bool {
    if std::env::var_os("SSH_CONNECTION").is_some() || std::env::var_os("SSH_TTY").is_some() {
        return false;
    }
    if cfg!(target_os = "linux") {
        return std::env::var_os("DISPLAY").is_some()
            || std::env::var_os("WAYLAND_DISPLAY").is_some();
    }
    true
}

/// Opens the sign-in page in the default browser when one can be opened here. True when it did.
pub fn open_in_browser(url: &str) -> bool {
    can_open_browser() && webbrowser::open(url).is_ok()
}

/// The name people see for this computer: the macOS "Computer Name" ("Ada's MacBook Pro"), else the host name.
pub fn default_device_name() -> String {
    #[cfg(target_os = "macos")]
    if let Ok(output) = std::process::Command::new("/usr/sbin/scutil")
        .args(["--get", "ComputerName"])
        .output()
        && output.status.success()
    {
        let name = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !name.is_empty() {
            return name;
        }
    }
    let host = gethostname::gethostname().to_string_lossy().to_string();
    let host = host.trim_end_matches(".local").trim();
    if host.is_empty() {
        "Computer".to_string()
    } else {
        host.to_string()
    }
}

/// "macOS 27.0", "Ubuntu 24.04.1 LTS", "Windows".
pub fn platform_label() -> String {
    #[cfg(target_os = "macos")]
    if let Ok(output) = std::process::Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        && output.status.success()
    {
        let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if !version.is_empty() {
            return format!("macOS {version}");
        }
    }
    #[cfg(target_os = "linux")]
    if let Ok(text) = std::fs::read_to_string("/etc/os-release")
        && let Some(name) = text
            .lines()
            .find_map(|line| line.strip_prefix("PRETTY_NAME="))
            .map(|value| value.trim_matches('"').to_string())
    {
        return name;
    }
    match std::env::consts::OS {
        "macos" => "macOS".to_string(),
        "windows" => "Windows".to_string(),
        "linux" => "Linux".to_string(),
        other => other.to_string(),
    }
}
