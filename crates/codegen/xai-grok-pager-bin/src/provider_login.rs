//! CLI provider login; no provider secret is accepted in a process argument.
use anyhow::{Context, Result, bail, ensure};
use tokio::io::AsyncReadExt;
use xai_grok_login::provider_auth::{self, KeyCheck, ModelProvider};
use xai_grok_pager::app::cli::LoginProvider;

const MAX_KEY_BYTES: usize = 16_384;

/// The first-run menu, in the order shown.
const SETUP_CHOICES: [(LoginProvider, &str); 5] = [
    (
        LoginProvider::OpenAiCodex,
        "OpenAI Codex (ChatGPT subscription)",
    ),
    (LoginProvider::Openrouter, "OpenRouter"),
    (LoginProvider::Deepseek, "DeepSeek (API key)"),
    (
        LoginProvider::Glm,
        "GLM Coding Plan (subscription from z.ai)",
    ),
    (
        LoginProvider::GlmCn,
        "GLM Coding Plan (subscription from bigmodel.cn, China mainland)",
    ),
];

/// Run before raw-mode startup so first-time users can choose their provider.
pub async fn first_run_setup() -> Result<()> {
    use std::io::{IsTerminal, Write};
    if !std::io::stdin().is_terminal() || !std::io::stderr().is_terminal() {
        return Ok(());
    }
    let cfg = xai_grok_shell::config::load_agent_config_disk_only().map_err(anyhow::Error::msg)?;
    if !xai_grok_shell::agent::builtin_providers::needs_provider_setup(&cfg) {
        return Ok(());
    }
    eprintln!("Welcome to Crok. Choose a provider to sign in:");
    for (number, (_, label)) in (1..).zip(SETUP_CHOICES) {
        eprintln!("  {number}. {label}");
    }
    let count = SETUP_CHOICES.len();
    loop {
        eprint!("Provider [1-{count}], or q to quit: ");
        std::io::stderr().flush()?;
        let mut input = String::new();
        ensure!(
            std::io::stdin().read_line(&mut input)? > 0,
            "Provider setup cancelled"
        );
        let choice = input.trim();
        if choice.eq_ignore_ascii_case("q") {
            bail!("Provider setup cancelled");
        }
        let chosen = choice
            .parse::<usize>()
            .ok()
            .and_then(|number| number.checked_sub(1))
            .and_then(|index| SETUP_CHOICES.get(index));
        match chosen {
            Some((provider, _)) => return login(*provider, false).await,
            None => eprintln!("Enter a number from 1 to {count}, or q."),
        }
    }
}

/// Remove one provider's stored credential, or every provider's when none is named.
pub async fn logout(provider: Option<LoginProvider>) -> Result<()> {
    let home = xai_grok_config::grok_home();
    let providers = match provider {
        Some(provider) => vec![provider.provider()],
        None => ModelProvider::ALL.to_vec(),
    };
    for provider in &providers {
        provider_auth::remove_provider_credential(&home, *provider).await?;
    }
    println!("Provider credentials removed.");
    // A key in the environment is not stored here, so it is still in use.
    for provider in providers {
        if let Some(var) = provider_auth::provider_api_key_env_var(provider) {
            println!(
                "{} is still signed in through {var}; unset it to sign out.",
                provider.display_name()
            );
        }
    }
    Ok(())
}

pub async fn login(provider: LoginProvider, with_api_key: bool) -> Result<()> {
    let provider = provider.provider();
    let home = xai_grok_config::grok_home();
    if with_api_key || !provider.has_browser_sign_in() {
        ensure!(
            provider.accepts_api_key(),
            "--with-api-key is for providers that sign in with a key; Codex subscription access uses browser OAuth"
        );
        let key = if with_api_key {
            read_piped_key(provider).await?
        } else {
            prompt_for_key(provider)?
        };
        save_key(&home, provider, key.trim()).await?;
    } else {
        provider_auth::login_with_oauth_input(&home, provider, |url| {
            eprintln!("Complete sign-in in your browser. If it does not open, visit:\n{url}\n");
            eprintln!("If the browser cannot reach this terminal, paste the full redirect URL here and press Enter.");
        }, read_redirect_url()).await?;
    }
    match provider {
        ModelProvider::OpenRouter => {
            println!("Signed in to OpenRouter.");
            let cfg = xai_grok_shell::config::load_agent_config_disk_only()
                .map_err(anyhow::Error::msg)?;
            match xai_grok_shell::agent::builtin_providers::refresh_openrouter_models(&cfg, true)
                .await
            {
                Ok(count) => println!(
                    "Discovered {count} models. The catalog refreshes automatically every hour."
                ),
                Err(error) => eprintln!(
                    "Signed in, but model discovery failed: {error}. Run `crok models --refresh` to retry."
                ),
            }
            println!(
                "Run `crok models`, then select with `crok --model openrouter/<provider>/<model>` or /model."
            );
        }
        ModelProvider::OpenAiCodex => {
            println!("Signed in to OpenAI Codex with your ChatGPT subscription.");
            println!(
                "Run `crok models`, then select an openai-codex/ model with --model or /model."
            );
        }
        ModelProvider::DeepSeek => {
            println!("Signed in to DeepSeek.");
            let cfg = xai_grok_shell::config::load_agent_config_disk_only()
                .map_err(anyhow::Error::msg)?;
            match xai_grok_shell::agent::builtin_providers::refresh_deepseek_models(&cfg, true)
                .await
            {
                Ok(count) => {
                    println!("Found {count} models. The list refreshes automatically every hour.")
                }
                Err(error) => eprintln!(
                    "Signed in, but the model list could not be fetched: {error}. Run `crok models --refresh` to retry."
                ),
            }
            println!(
                "Run `crok models`, then select with `crok --model deepseek/<model>` or /model."
            );
        }
        ModelProvider::Glm | ModelProvider::GlmCn => {
            let site = if provider == ModelProvider::Glm {
                "z.ai"
            } else {
                "bigmodel.cn"
            };
            println!("Signed in to your GLM Coding Plan on {site}.");
            println!(
                "Select a model with `crok --model {provider}/glm-5.3`, `crok --model {provider}/glm-5.3-flash`, or /model."
            );
        }
    }
    Ok(())
}

/// Ask the provider about the key, then store it. A key the provider refuses is not stored.
async fn save_key(home: &std::path::Path, provider: ModelProvider, key: &str) -> Result<()> {
    let name = provider.display_name();
    ensure!(!key.is_empty(), "No {name} API key was given");
    match provider_auth::check_provider_api_key(provider, key).await {
        KeyCheck::Accepted => {}
        KeyCheck::Rejected(why) => bail!("{why} Nothing was saved."),
        KeyCheck::Unverified(why) => {
            eprintln!("The key could not be checked ({why}), so it is saved as given.")
        }
    }
    provider_auth::store_provider_api_key(home, provider, key).await?;
    if let Some(var) = provider_auth::provider_api_key_env_var(provider) {
        eprintln!("Note: {var} is set and takes precedence over the saved key.");
    }
    Ok(())
}

/// `printenv SOME_API_KEY | crok login <provider> --with-api-key`
async fn read_piped_key(provider: ModelProvider) -> Result<String> {
    use std::io::IsTerminal;
    let var = provider
        .api_key_env_vars()
        .first()
        .copied()
        .unwrap_or("API_KEY");
    ensure!(
        !std::io::stdin().is_terminal(),
        "Pipe your key to stdin: printenv {var} | crok login {provider} --with-api-key"
    );
    let mut key = String::new();
    tokio::io::stdin()
        .take(MAX_KEY_BYTES as u64 + 1)
        .read_to_string(&mut key)
        .await
        .context("Could not read API key from stdin")?;
    ensure!(key.len() <= MAX_KEY_BYTES, "API key input is too large");
    Ok(key)
}

/// Ask for the key in the terminal, without showing it.
fn prompt_for_key(provider: ModelProvider) -> Result<String> {
    use std::io::{IsTerminal, Write};
    let name = provider.display_name();
    let var = provider
        .api_key_env_vars()
        .first()
        .copied()
        .unwrap_or("API_KEY");
    ensure!(
        std::io::stdin().is_terminal() && std::io::stderr().is_terminal(),
        "{name} signs in with an API key, which needs a terminal to type into. \
         Without one, pipe it: printenv {var} | crok login {provider} --with-api-key"
    );
    eprintln!("{name} signs in with an API key.");
    match provider {
        ModelProvider::Glm => eprintln!(
            "Use the key of the account that holds your subscription on z.ai. \
             Subscribed on bigmodel.cn instead? Run `crok login glm-cn`."
        ),
        ModelProvider::GlmCn => eprintln!(
            "Use the key of the account that holds your subscription on bigmodel.cn. \
             Subscribed on z.ai instead? Run `crok login glm`."
        ),
        _ => {}
    }
    if let Some(page) = provider.api_key_page() {
        eprintln!("Create one at {page}");
    }
    eprint!("Paste the key and press Enter (it stays hidden): ");
    std::io::stderr().flush()?;
    let key = read_secret_line()?;
    ensure!(
        !key.trim().is_empty(),
        "No key was entered; nothing was saved"
    );
    Ok(key)
}

/// One line from the terminal, with echo off while it is typed.
#[cfg(unix)]
fn read_secret_line() -> Result<String> {
    use std::io::Read;
    use std::os::fd::AsRawFd;

    /// Puts the terminal back however the read ends.
    struct Restore {
        fd: libc::c_int,
        saved: libc::termios,
    }
    impl Drop for Restore {
        fn drop(&mut self) {
            // SAFETY: `fd` is this process's stdin and `saved` is what `tcgetattr` read from it.
            unsafe { libc::tcsetattr(self.fd, libc::TCSANOW, &self.saved) };
        }
    }

    let stdin = std::io::stdin();
    let fd = stdin.as_raw_fd();
    // SAFETY: an all-zero `termios` is a valid value for `tcgetattr` to overwrite.
    let mut saved: libc::termios = unsafe { std::mem::zeroed() };
    // SAFETY: `fd` is open for the life of the process and `saved` is a valid out-pointer.
    let read = unsafe { libc::tcgetattr(fd, &mut saved) };
    ensure!(read == 0, "Cannot read the terminal's settings");
    let restore = Restore { fd, saved };
    let mut quiet = saved;
    // Ctrl-C arrives as a byte rather than a signal, which would end the process with echo still off.
    quiet.c_lflag &= !(libc::ECHO | libc::ICANON | libc::ISIG);
    if let Some(min) = quiet.c_cc.get_mut(libc::VMIN) {
        *min = 1;
    }
    if let Some(time) = quiet.c_cc.get_mut(libc::VTIME) {
        *time = 0;
    }
    // SAFETY: as above; `quiet` is a copy of the settings just read, with three flags cleared.
    let written = unsafe { libc::tcsetattr(fd, libc::TCSANOW, &quiet) };
    ensure!(written == 0, "Cannot hide what is typed in this terminal");

    let mut key = Vec::new();
    let mut input = stdin.lock();
    let cancelled = loop {
        let mut byte = [0u8; 1];
        if input.read(&mut byte)? == 0 {
            break false;
        }
        let [byte] = byte;
        match byte {
            b'\r' | b'\n' => break false,
            // Ctrl-C, or Ctrl-D on an empty line.
            3 => break true,
            4 if key.is_empty() => break true,
            8 | 127 => {
                key.pop();
            }
            byte if byte.is_ascii_control() => {}
            byte => key.push(byte),
        }
        ensure!(key.len() <= MAX_KEY_BYTES, "API key input is too large");
    };
    drop(restore);
    eprintln!();
    ensure!(!cancelled, "Sign-in cancelled");
    String::from_utf8(key).context("The key is not valid text")
}

#[cfg(not(unix))]
fn read_secret_line() -> Result<String> {
    let mut key = String::new();
    std::io::stdin()
        .read_line(&mut key)
        .context("Could not read the API key")?;
    Ok(key)
}

async fn read_redirect_url() -> Result<String> {
    use std::io::IsTerminal;
    if !std::io::stdin().is_terminal() {
        return std::future::pending().await;
    }
    // A detached OS thread avoids an uncancellable Tokio stdin blocking task
    // keeping the runtime alive after the HTTP callback has already completed.
    let (tx, rx) = tokio::sync::oneshot::channel();
    std::thread::Builder::new()
        .name("provider-login-input".into())
        .spawn(move || {
            let mut line = String::new();
            let result = std::io::stdin()
                .read_line(&mut line)
                .context("Could not read the OAuth redirect URL")
                .map(|_| line);
            let _ = tx.send(result);
        })?;
    rx.await.context("OAuth input reader stopped")?
}
