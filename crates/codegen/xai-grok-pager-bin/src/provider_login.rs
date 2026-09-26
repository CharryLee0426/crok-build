//! CLI provider login; no provider secret is accepted in a process argument.
use anyhow::{Context, Result, ensure};
use tokio::io::AsyncReadExt;
use xai_grok_login::provider_auth::{self, ModelProvider};
use xai_grok_pager::app::cli::LoginProvider;

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
    eprintln!("Welcome to Grok. Choose a provider to sign in:");
    eprintln!("  1. OpenAI Codex (ChatGPT subscription)");
    eprintln!("  2. OpenRouter");
    loop {
        eprint!("Provider [1-2], or q to quit: ");
        std::io::stderr().flush()?;
        let mut input = String::new();
        ensure!(
            std::io::stdin().read_line(&mut input)? > 0,
            "Provider setup cancelled"
        );
        match input.trim() {
            "1" => return login(LoginProvider::OpenAiCodex, false).await,
            "2" => return login(LoginProvider::Openrouter, false).await,
            "q" | "Q" => anyhow::bail!("Provider setup cancelled"),
            _ => eprintln!("Enter 1, 2, or q."),
        }
    }
}

/// Remove one provider's stored credential, or every provider's when none is named.
pub async fn logout(provider: Option<LoginProvider>) -> Result<()> {
    let home = xai_grok_config::grok_home();
    let providers = match provider {
        Some(provider) => vec![provider.provider()],
        None => vec![ModelProvider::OpenAiCodex, ModelProvider::OpenRouter],
    };
    for provider in providers {
        provider_auth::remove_provider_credential(&home, provider).await?;
    }
    println!("Provider credentials removed.");
    Ok(())
}

pub async fn login(provider: LoginProvider, with_api_key: bool) -> Result<()> {
    let provider = provider.provider();
    let home = xai_grok_config::grok_home();
    if with_api_key {
        ensure!(
            provider == ModelProvider::OpenRouter,
            "--with-api-key is for OpenRouter; Codex subscription access uses browser OAuth"
        );
        use std::io::IsTerminal;
        ensure!(
            !std::io::stdin().is_terminal(),
            "Pipe your key to stdin: printenv OPENROUTER_API_KEY | grok login openrouter --with-api-key"
        );
        let mut key = String::new();
        tokio::io::stdin()
            .take(16_385)
            .read_to_string(&mut key)
            .await
            .context("Could not read API key from stdin")?;
        ensure!(key.len() <= 16_384, "API key input is too large");
        provider_auth::store_openrouter_api_key(&home, key.trim()).await?;
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
                    "Signed in, but model discovery failed: {error}. Run `grok models --refresh` to retry."
                ),
            }
            println!(
                "Run `grok models`, then select with `grok --model openrouter/<provider>/<model>` or /model."
            );
        }
        ModelProvider::OpenAiCodex => {
            println!("Signed in to OpenAI Codex with your ChatGPT subscription.");
            println!(
                "Run `grok models`, then select an openai-codex/ model with --model or /model."
            );
        }
    }
    Ok(())
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
