//! Finding the latest release and its signed manifest.
//!
//! The version comes from the redirect behind `<repo>/releases/latest`, which GitHub serves
//! without the API's rate limit. The manifest `SHA256SUMS.txt` is the list of what the release
//! carries; its signature is checked before anything in it is believed. The release notes come
//! from the API when it answers and are only shown, never trusted.

use std::path::Path;

use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use sha2::Digest;

use crate::sshsig::TrustedKeys;

pub const DEFAULT_REPO_URL: &str = "https://github.com/CharryLee0426/crok-build";

/// Where releases are published. `CROK_UPGRADE_REPO_URL` points a test at a local server;
/// `CROK_UPGRADE_API_URL` replaces the GitHub API base for release notes (empty disables it).
#[derive(Debug, Clone)]
pub struct Source {
    pub repo_url: String,
    pub api_url: Option<String>,
}

impl Source {
    pub fn from_env() -> Self {
        let repo_url = std::env::var("CROK_UPGRADE_REPO_URL")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_REPO_URL.to_string());
        let repo_url = repo_url.trim_end_matches('/').to_string();
        let api_url = match std::env::var("CROK_UPGRADE_API_URL") {
            Ok(value) if value.trim().is_empty() => None,
            Ok(value) => Some(value.trim_end_matches('/').to_string()),
            Err(_) => repo_url
                .strip_prefix("https://github.com/")
                .map(|path| format!("https://api.github.com/repos/{path}")),
        };
        Self { repo_url, api_url }
    }

    pub fn latest_url(&self) -> String {
        format!("{}/releases/latest", self.repo_url)
    }

    pub fn tag_url(&self, tag: &str) -> String {
        format!("{}/releases/tag/{tag}", self.repo_url)
    }

    pub fn asset_url(&self, tag: &str, name: &str) -> String {
        format!("{}/releases/download/{tag}/{name}", self.repo_url)
    }
}

/// A published release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub tag: String,
    pub version: semver::Version,
    /// The release page.
    pub page_url: String,
    /// Markdown from the release page, when the API answered.
    pub notes: Option<String>,
}

/// Release tags are `desktop-v1.4.0` (the historical form) or `v1.5.0`.
pub fn version_from_tag(tag: &str) -> Option<semver::Version> {
    let bare = tag
        .strip_prefix("desktop-v")
        .or_else(|| tag.strip_prefix('v'))
        .unwrap_or(tag);
    semver::Version::parse(bare).ok()
}

pub fn client(timeout: std::time::Duration, follow_redirects: bool) -> Result<reqwest::Client> {
    xai_grok_extra_ca::build_reqwest_client(|builder| {
        let builder = builder
            .user_agent(format!("crok-upgrade/{}", env!("CARGO_PKG_VERSION")))
            .connect_timeout(std::time::Duration::from_secs(30))
            .timeout(timeout);
        if follow_redirects {
            builder
        } else {
            builder.redirect(reqwest::redirect::Policy::none())
        }
    })
    .context("building the HTTP client")
}

/// The newest release, from the `releases/latest` redirect.
pub async fn latest(source: &Source, with_notes: bool) -> Result<Release> {
    let client = client(std::time::Duration::from_secs(60), false)?;
    let response = client
        .get(source.latest_url())
        .send()
        .await
        .context("reaching the release page")?;
    let status = response.status();
    if !status.is_redirection() {
        if status == reqwest::StatusCode::NOT_FOUND {
            bail!("no release has been published at {}", source.repo_url);
        }
        bail!("unexpected answer {status} from {}", source.latest_url());
    }
    let location = response
        .headers()
        .get(reqwest::header::LOCATION)
        .and_then(|value| value.to_str().ok())
        .context("the release page redirect has no location")?;
    let tag = location
        .rsplit_once("/releases/tag/")
        .map(|(_, tag)| tag.trim_end_matches('/'))
        .filter(|tag| !tag.is_empty())
        .with_context(|| format!("unexpected release redirect to {location}"))?;
    let tag = percent_decode(tag);
    let version = version_from_tag(&tag)
        .with_context(|| format!("the latest release tag {tag:?} is not a version"))?;
    let page_url = source.tag_url(&tag);
    let notes = if with_notes {
        fetch_notes(source, &tag).await
    } else {
        None
    };
    Ok(Release {
        tag,
        version,
        page_url,
        notes,
    })
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if byte == b'%'
            && let Some(hex) = bytes.get(index + 1..index + 3)
            && let Ok(text) = std::str::from_utf8(hex)
            && let Ok(decoded) = u8::from_str_radix(text, 16)
        {
            out.push(decoded);
            index += 3;
            continue;
        }
        out.push(byte);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Release notes are decoration: any failure leaves them out.
async fn fetch_notes(source: &Source, tag: &str) -> Option<String> {
    let api = source.api_url.as_ref()?;
    let client = client(std::time::Duration::from_secs(30), true).ok()?;
    let response = client
        .get(format!("{api}/releases/tags/{tag}"))
        .header(reqwest::header::ACCEPT, "application/vnd.github+json")
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let value: serde_json::Value = response.json().await.ok()?;
    value
        .get("body")
        .and_then(|body| body.as_str())
        .map(|body| body.trim().to_string())
        .filter(|body| !body.is_empty())
}

/// `SHA256SUMS.txt`: `<hex>  <file name>` per line, as `shasum -a 256` writes it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Manifest {
    entries: Vec<(String, String)>,
    pub text: Vec<u8>,
}

impl Manifest {
    pub fn parse(text: Vec<u8>) -> Result<Self> {
        let mut entries = Vec::new();
        for (index, line) in String::from_utf8_lossy(&text).lines().enumerate() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (hash, name) = line
                .split_once(char::is_whitespace)
                .with_context(|| format!("{}:{}: not a checksum line", crate::MANIFEST_NAME, index + 1))?;
            let name = name.trim().trim_start_matches('*');
            if hash.len() != 64 || !hash.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                bail!(
                    "{}:{}: {hash:?} is not a SHA-256 hash",
                    crate::MANIFEST_NAME,
                    index + 1
                );
            }
            if name.is_empty() || name.contains('/') || name.contains("..") {
                bail!(
                    "{}:{}: {name:?} is not a plain file name",
                    crate::MANIFEST_NAME,
                    index + 1
                );
            }
            entries.push((name.to_string(), hash.to_ascii_lowercase()));
        }
        if entries.is_empty() {
            bail!("{} lists no files", crate::MANIFEST_NAME);
        }
        Ok(Self { entries, text })
    }

    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().map(|(name, _)| name.as_str())
    }

    /// The listed name matching `wanted` regardless of case, with its hash.
    pub fn find(&self, wanted: &str) -> Option<(&str, &str)> {
        self.entries
            .iter()
            .find(|(name, _)| name.eq_ignore_ascii_case(wanted))
            .map(|(name, hash)| (name.as_str(), hash.as_str()))
    }

    /// Checks the signature made with `ssh-keygen -Y sign -n crok-release`.
    pub fn verify(&self, armored_signature: &str, keys: &TrustedKeys) -> Result<()> {
        keys.verify(&self.text, armored_signature, crate::SIGNATURE_NAMESPACE)
            .with_context(|| format!("{} is not signed by a crok release key", crate::MANIFEST_NAME))
    }
}

/// Downloads and verifies the release's manifest.
pub async fn fetch_manifest(source: &Source, tag: &str, keys: &TrustedKeys) -> Result<Manifest> {
    let client = client(std::time::Duration::from_secs(60), true)?;
    let text = fetch_small(&client, &source.asset_url(tag, crate::MANIFEST_NAME)).await?;
    let signature = fetch_small(&client, &source.asset_url(tag, crate::SIGNATURE_NAME)).await?;
    let manifest = Manifest::parse(text)?;
    manifest.verify(&String::from_utf8_lossy(&signature), keys)?;
    Ok(manifest)
}

async fn fetch_small(client: &reqwest::Client, url: &str) -> Result<Vec<u8>> {
    let response = client
        .get(url)
        .send()
        .await
        .with_context(|| format!("downloading {url}"))?;
    let status = response.status();
    if !status.is_success() {
        bail!("{url} answered {status}");
    }
    let bytes = response
        .bytes()
        .await
        .with_context(|| format!("downloading {url}"))?;
    if bytes.len() > 1 << 20 {
        bail!("{url} is larger than a manifest can be");
    }
    Ok(bytes.to_vec())
}

/// Streams `url` into `dest`, reporting `(received, total)` as bytes arrive.
pub async fn download(
    url: &str,
    dest: &Path,
    mut progress: impl FnMut(u64, Option<u64>),
) -> Result<()> {
    let client = client(std::time::Duration::from_secs(60 * 30), true)?;
    let response = client
        .get(url)
        .send()
        .await
        .with_context(|| format!("downloading {url}"))?;
    let status = response.status();
    if !status.is_success() {
        bail!("{url} answered {status}");
    }
    let total = response.content_length();
    let parent = dest.parent().context("download path has no parent")?;
    std::fs::create_dir_all(parent)?;
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    let mut received = 0u64;
    let mut stream = response.bytes_stream();
    progress(0, total);
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.with_context(|| format!("downloading {url}"))?;
        std::io::Write::write_all(&mut file, &chunk)?;
        received += chunk.len() as u64;
        progress(received, total);
    }
    file.persist(dest)
        .with_context(|| format!("saving {}", dest.display()))?;
    Ok(())
}

/// The lowercase hex SHA-256 of a file.
pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file = std::fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut hasher = sha2::Sha256::new();
    std::io::copy(&mut file, &mut hasher)?;
    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_with_either_prefix_are_versions() {
        assert_eq!(
            version_from_tag("desktop-v1.4.0"),
            Some(semver::Version::new(1, 4, 0))
        );
        assert_eq!(version_from_tag("v1.5.0"), Some(semver::Version::new(1, 5, 0)));
        assert_eq!(version_from_tag("1.5.1"), Some(semver::Version::new(1, 5, 1)));
        assert_eq!(version_from_tag("nightly"), None);
    }

    #[test]
    fn manifest_lines_are_parsed_and_matched_without_case() {
        let text = b"334e7ea9e0d973d119f473084e854590569ac8416e8877be2c0b8ef5d5319b80  Crok-Desktop-1.4.0-arm64-macOS15-SDK.dmg\n\
917ec414afbf7c76faeddde54aaf381d4410a815f4d29e1402257823e511c74a  Crok-Desktop-1.4.0-arm64-macOS26-SDK.dmg\n"
            .to_vec();
        let manifest = Manifest::parse(text).unwrap();
        assert_eq!(manifest.names().count(), 2);
        let (name, hash) = manifest
            .find("crok-desktop-1.4.0-arm64-macos26-sdk.dmg")
            .unwrap();
        assert_eq!(name, "Crok-Desktop-1.4.0-arm64-macOS26-SDK.dmg");
        assert!(hash.starts_with("917ec414"));
        assert!(manifest.find("missing.dmg").is_none());
    }

    #[test]
    fn manifest_rejects_paths_and_bad_hashes() {
        assert!(Manifest::parse(b"abc  file.dmg\n".to_vec()).is_err());
        let hash = "0".repeat(64);
        assert!(Manifest::parse(format!("{hash}  ../file.dmg\n").into_bytes()).is_err());
        assert!(Manifest::parse(format!("{hash}  dir/file.dmg\n").into_bytes()).is_err());
        assert!(Manifest::parse(b"\n".to_vec()).is_err());
        assert!(Manifest::parse(format!("{hash}  file.dmg\n").into_bytes()).is_ok());
    }

    #[test]
    fn source_urls() {
        let source = Source {
            repo_url: "https://github.com/CharryLee0426/crok-build".into(),
            api_url: Some("https://api.github.com/repos/CharryLee0426/crok-build".into()),
        };
        assert_eq!(
            source.asset_url("desktop-v1.4.0", "SHA256SUMS.txt"),
            "https://github.com/CharryLee0426/crok-build/releases/download/desktop-v1.4.0/SHA256SUMS.txt"
        );
        assert_eq!(
            source.latest_url(),
            "https://github.com/CharryLee0426/crok-build/releases/latest"
        );
    }

    #[test]
    fn percent_decoding() {
        assert_eq!(percent_decode("desktop-v1.4.0"), "desktop-v1.4.0");
        assert_eq!(percent_decode("v1.5.0%2Brc"), "v1.5.0+rc");
        assert_eq!(percent_decode("bad%zz"), "bad%zz");
    }
}
