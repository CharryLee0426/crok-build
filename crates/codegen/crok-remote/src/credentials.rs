//! This computer's link to the relay: `$CROK_HOME/remote/credentials.json`, owner-only (0600 in a 0700 directory),
//! written atomically. Like `provider-auth/*.json`, it is a plain file on purpose: the TUI, Crok Desktop and every task
//! process read it, and none of them can prompt for a keychain.

use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::Context;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub image_url: Option<String>,
}

impl Account {
    /// "Ada Lovelace (ada@example.com)", or whichever of the two is known.
    pub fn display(&self) -> String {
        match (&self.name, &self.email) {
            (Some(name), Some(email)) => format!("{name} ({email})"),
            (Some(name), None) => name.clone(),
            (None, Some(email)) => email.clone(),
            (None, None) => String::new(),
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credentials {
    /// The relay (Convex deployment URL) that issued them.
    pub server: String,
    pub device_id: String,
    /// Long-lived; traded for one-hour access JWTs. Only its hash is on the relay.
    pub refresh_token: String,
    pub device_name: String,
    #[serde(default)]
    pub account: Account,
    /// Unix milliseconds.
    pub linked_at: i64,
}

impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credentials")
            .field("server", &self.server)
            .field("device_id", &self.device_id)
            .field("refresh_token", &"<redacted>")
            .field("device_name", &self.device_name)
            .field("account", &self.account)
            .field("linked_at", &self.linked_at)
            .finish()
    }
}

pub fn dir() -> PathBuf {
    xai_dirs::grok_home().join("remote")
}

pub fn path() -> PathBuf {
    dir().join("credentials.json")
}

pub fn load() -> anyhow::Result<Option<Credentials>> {
    load_from(&path())
}

pub fn load_from(path: &Path) -> anyhow::Result<Option<Credentials>> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .with_context(|| format!("{} is not valid", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("reading {}", path.display())),
    }
}

pub fn save(credentials: &Credentials) -> anyhow::Result<()> {
    save_to(&path(), credentials)
}

pub fn save_to(path: &Path, credentials: &Credentials) -> anyhow::Result<()> {
    let dir = path.parent().context("credentials path has no directory")?;
    std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    }
    let tmp = dir.join(format!(".credentials.{}.tmp", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = options
        .open(&tmp)
        .with_context(|| format!("creating {}", tmp.display()))?;
    file.write_all(&serde_json::to_vec_pretty(credentials)?)?;
    file.sync_all()?;
    drop(file);
    std::fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

/// Deletes the saved link. True when there was one.
pub fn remove() -> anyhow::Result<bool> {
    remove_at(&path())
}

pub fn remove_at(path: &Path) -> anyhow::Result<bool> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("deleting {}", path.display())),
    }
}

/// When the file last changed, so long-running processes notice a sign-in or sign-out made elsewhere.
pub fn modified() -> Option<std::time::SystemTime> {
    std::fs::metadata(path()).and_then(|m| m.modified()).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Credentials {
        Credentials {
            server: "https://x.convex.cloud".into(),
            device_id: "d1".into(),
            refresh_token: "crr_secret".into(),
            device_name: "Mac".into(),
            account: Account {
                name: Some("Ada".into()),
                email: Some("ada@example.com".into()),
                image_url: None,
            },
            linked_at: 1,
        }
    }

    #[test]
    fn round_trips_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("remote").join("credentials.json");
        save_to(&path, &sample()).unwrap();
        assert_eq!(load_from(&path).unwrap(), Some(sample()));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        assert!(remove_at(&path).unwrap());
        assert!(!remove_at(&path).unwrap());
        assert_eq!(load_from(&path).unwrap(), None);
    }

    #[test]
    fn debug_hides_the_token() {
        let text = format!("{:?}", sample());
        assert!(!text.contains("crr_secret"));
    }

    #[test]
    fn account_display() {
        assert_eq!(sample().account.display(), "Ada (ada@example.com)");
        assert_eq!(Account::default().display(), "");
    }
}
