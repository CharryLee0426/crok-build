//! `crok remote login | logout | status`. With `--json`, one JSON object per line on stdout for Crok Desktop:
//! `{"event":"code",…}`, `{"event":"signed_in",…}`, `{"event":"signed_out"}`, `{"event":"status",…}`,
//! `{"event":"error","message":…}`.

use std::io::{IsTerminal, Write};

use anyhow::bail;
use serde_json::{Value, json};
use xai_grok_i18n::{tl, tlf};

use crate::api::Api;
use crate::credentials::{self, Credentials};
use crate::login::{self, LoginError, LoginRequest};
use crate::settings;

#[derive(Clone, Debug)]
pub enum Action {
    Login {
        server: Option<String>,
        name: Option<String>,
        no_browser: bool,
        force: bool,
    },
    Logout,
    Status,
}

#[derive(Clone, Debug)]
pub struct Options {
    pub action: Action,
    pub json: bool,
    /// What this computer runs, as shown on the Devices screen ("crok 1.0.45").
    pub client: String,
}

struct Out {
    json: bool,
}

impl Out {
    fn event(&self, value: Value) {
        if !self.json {
            return;
        }
        let mut stdout = std::io::stdout().lock();
        let _ = serde_json::to_writer(&mut stdout, &value);
        let _ = stdout.write_all(b"\n");
        let _ = stdout.flush();
    }

    fn line(&self, text: impl AsRef<str>) {
        if self.json {
            return;
        }
        println!("{}", text.as_ref());
    }
}

pub async fn run(options: Options) -> anyhow::Result<()> {
    let out = Out { json: options.json };
    let result = match &options.action {
        Action::Login {
            server,
            name,
            no_browser,
            force,
        } => {
            login_command(
                &out,
                &options,
                server.as_deref(),
                name.as_deref(),
                *no_browser,
                *force,
            )
            .await
        }
        Action::Logout => logout_command(&out).await,
        Action::Status => status_command(&out).await,
    };
    if let Err(error) = &result {
        out.event(json!({ "event": "error", "message": format!("{error:#}") }));
    }
    result
}

fn account_json(credentials: &Credentials) -> Value {
    json!({
        "name": credentials.account.name,
        "email": credentials.account.email,
        "imageUrl": credentials.account.image_url,
    })
}

fn who(credentials: &Credentials) -> String {
    let display = credentials.account.display();
    if display.is_empty() {
        tl("your account").to_string()
    } else {
        display
    }
}

async fn login_command(
    out: &Out,
    options: &Options,
    server: Option<&str>,
    name: Option<&str>,
    no_browser: bool,
    force: bool,
) -> anyhow::Result<()> {
    if let Some(existing) = credentials::load()? {
        if !force {
            bail!(
                "{}",
                tlf(
                    "Already signed in as {account} on {server}. Run `crok remote logout` first, or pass --force.",
                    &[("account", &who(&existing)), ("server", &existing.server)],
                )
            );
        }
        if let Ok(api) = Api::new(&existing.server) {
            let _ = tokio::time::timeout(
                std::time::Duration::from_secs(10),
                api.logout(&existing.refresh_token),
            )
            .await;
        }
        credentials::remove()?;
    }
    let server = settings::server_url(server, None);
    settings::validate_url(&server)?;
    let request = LoginRequest {
        server: server.clone(),
        device_name: name
            .map(str::trim)
            .filter(|n| !n.is_empty())
            .map(str::to_owned)
            .unwrap_or_else(login::default_device_name),
        platform: login::platform_label(),
        client: options.client.clone(),
    };
    let api = Api::new(&server)?;
    let start = login::begin(&api, &request)
        .await
        .map_err(anyhow::Error::new)?;
    out.event(json!({
        "event": "code",
        "userCode": start.user_code,
        "verificationUrl": start.verification_url,
        "verificationUrlComplete": start.verification_url_complete,
        "expiresAt": start.expires_at as i64,
        "server": server,
        "deviceName": request.device_name,
    }));
    out.line(tl("Sign in to crok remote control"));
    out.line("");
    if let Some(url) = &start.verification_url_complete {
        out.line(format!("  {}  {url}", tl("Open:")));
    }
    out.line(format!("  {}  {}", tl("Code:"), start.user_code));
    out.line("");
    let qr_target = start
        .verification_url_complete
        .as_deref()
        .unwrap_or(&start.user_code);
    if !out.json
        && let Some(lines) = crate::qr::render(qr_target, std::io::stdout().is_terminal())
    {
        for line in lines {
            println!("  {line}");
        }
        out.line(format!(
            "  {}",
            tl("Or scan it with the Crok app on your phone: Settings › Link a computer.")
        ));
        out.line("");
    }
    if start.verification_url_complete.is_none() {
        out.line(tl(
            "This relay has no web address set (CROK_WEB_URL), so approve the code from the Crok app on your phone.",
        ));
    }
    let opened = !no_browser
        && start
            .verification_url_complete
            .as_deref()
            .is_some_and(login::open_in_browser);
    if opened {
        out.line(tl("Opened the page in your browser. Sign in with GitHub or Google there and approve this computer."));
    }
    out.line(tl("Waiting for approval… (Ctrl-C to cancel)"));
    let credentials = tokio::select! {
        result = login::wait(&api, &request, &start) => match result {
            Ok(credentials) => credentials,
            Err(LoginError::Other(error)) => return Err(error),
            Err(error) => bail!("{error}"),
        },
        _ = tokio::signal::ctrl_c() => bail!("{}", tl("Sign-in cancelled.")),
    };
    out.event(json!({
        "event": "signed_in",
        "account": account_json(&credentials),
        "deviceName": credentials.device_name,
        "deviceId": credentials.device_id,
        "server": credentials.server,
    }));
    out.line(format!(
        "✓ {}",
        tlf(
            "Signed in as {account}. This computer is “{device}”.",
            &[
                ("account", &who(&credentials)),
                ("device", &credentials.device_name)
            ],
        )
    ));
    out.line(format!(
        "  {}",
        tl("Sessions you run in crok and Crok Desktop now show up in the Crok app and on the web.")
    ));
    if !settings::load().enabled {
        out.line(format!(
            "  {}",
            tl("Remote control is turned off in [remote] enabled; turn it on to share sessions.")
        ));
    }
    Ok(())
}

async fn logout_command(out: &Out) -> anyhow::Result<()> {
    let Some(existing) = credentials::load()? else {
        out.event(json!({ "event": "signed_out", "wasSignedIn": false }));
        out.line(tl("This computer is not signed in to remote control."));
        return Ok(());
    };
    // Unlink on the relay too, so the device disappears from the phone. Best effort: offline still signs out here.
    let unlinked = match Api::new(&existing.server) {
        Ok(api) => matches!(
            tokio::time::timeout(
                std::time::Duration::from_secs(10),
                api.logout(&existing.refresh_token)
            )
            .await,
            Ok(Ok(()))
        ),
        Err(_) => false,
    };
    credentials::remove()?;
    out.event(json!({ "event": "signed_out", "wasSignedIn": true, "unlinked": unlinked }));
    out.line(format!(
        "✓ {}",
        tl("Signed out. This computer no longer shares its sessions.")
    ));
    if !unlinked {
        out.line(format!(
            "  {}",
            tl("The relay could not be reached; remove this computer from Devices on your phone or the web.")
        ));
    }
    Ok(())
}

async fn status_command(out: &Out) -> anyhow::Result<()> {
    let settings = settings::load();
    let Some(existing) = credentials::load()? else {
        out.event(json!({
            "event": "status",
            "signedIn": false,
            "enabled": settings.enabled,
            "server": settings::server_url(None, None),
        }));
        out.line(tl("Remote control: not signed in"));
        out.line(format!("  {}", tl("Run `crok remote login` to follow and steer this computer's sessions from your phone.")));
        return Ok(());
    };
    // Check the link is still good (it is revoked when the device is signed out from another device).
    let valid = match Api::new(&existing.server) {
        Ok(api) => match tokio::time::timeout(
            std::time::Duration::from_secs(8),
            api.refresh(&existing.refresh_token),
        )
        .await
        {
            Ok(Ok(_)) => Some(true),
            Ok(Err(error)) if error.is_revoked() => Some(false),
            _ => None,
        },
        Err(_) => None,
    };
    if valid == Some(false) {
        credentials::remove()?;
    }
    out.event(json!({
        "event": "status",
        "signedIn": valid != Some(false),
        "revoked": valid == Some(false),
        "reachable": valid.is_some(),
        "enabled": settings.enabled,
        "server": existing.server,
        "account": account_json(&existing),
        "deviceName": existing.device_name,
        "deviceId": existing.device_id,
        "linkedAt": existing.linked_at,
    }));
    if valid == Some(false) {
        out.line(tl(
            "Remote control: this computer was signed out from another device.",
        ));
        out.line(format!(
            "  {}",
            tl("Run `crok remote login` to sign in again.")
        ));
        return Ok(());
    }
    out.line(tl("Remote control: signed in"));
    out.line(format!("  {:<10}{}", tl("Account:"), who(&existing)));
    out.line(format!("  {:<10}{}", tl("Computer:"), existing.device_name));
    out.line(format!("  {:<10}{}", tl("Relay:"), existing.server));
    out.line(format!(
        "  {:<10}{}",
        tl("Control:"),
        if settings.enabled {
            tl("on")
        } else {
            tl("off ([remote] enabled = false)")
        }
    ));
    if valid.is_none() {
        out.line(format!(
            "  {}",
            tl("The relay could not be reached right now.")
        ));
    }
    Ok(())
}
