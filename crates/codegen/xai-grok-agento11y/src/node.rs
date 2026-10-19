//! Finding a JavaScript runtime for the bridge, and fetching one for a machine that has none.
//!
//! Crok Desktop starts from Finder with launchd's short PATH (plus Homebrew's), so a Node
//! installed by nvm is not on it: the usual install places are searched too. A machine with no
//! Node 20 or newer (or Bun) gets the official Node build pinned below, downloaded once into
//! `~/.crok/agento11y/` and checked against its SHA-256, so every install can report.

use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, Read, Seek, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use sha2::{Digest, Sha256};

/// The oldest Node the bundled bridge runs on.
const MIN_NODE_MAJOR: u32 = 20;
/// The Node a machine without one gets: an active LTS release.
const NODE_VERSION: &str = "v24.21.0";
const NODE_DIST: &str = "https://nodejs.org/dist";
/// SHA-256 of each `node-<version>-<platform>.tar.gz`, from the release's SHASUMS256.txt.
const NODE_SHA256: [(&str, &str); 4] = [
    (
        "darwin-arm64",
        "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057",
    ),
    (
        "darwin-x64",
        "1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097",
    ),
    (
        "linux-arm64",
        "724282c3b43aec998aa9527380465b45d229e021b58035f5f4f63095eabfe5d5",
    ),
    (
        "linux-x64",
        "6e1db87ef58b8819e5d5402eff1536491b18edd8eb7bee5ef7897876e88dc5ff",
    ),
];

/// A runtime for the bridge: `explicit` (`CROK_AGENTO11Y_NODE`) when set, else one on this machine
/// ([`find_runtime`]), else the pinned Node, downloaded into `dir` the first time.
pub(crate) fn ensure_runtime(
    explicit: Option<&str>,
    path: Option<&OsStr>,
    home: Option<&Path>,
    dir: &Path,
) -> Result<PathBuf, String> {
    if let Some(explicit) = explicit.filter(|p| !p.trim().is_empty()) {
        return find_runtime(Some(explicit), None, None).ok_or_else(|| {
            format!(
                "CROK_AGENTO11Y_NODE names {explicit}, which is not Node {MIN_NODE_MAJOR}+ or Bun"
            )
        });
    }
    if let Some(found) = find_runtime(None, path, home) {
        return Ok(found);
    }
    let build = NodeBuild::pinned(NODE_DIST).ok_or_else(|| {
        format!(
            "no Node.js {MIN_NODE_MAJOR}+ on this machine and no Node build to download for {}-{}: install Node {MIN_NODE_MAJOR}+ or set CROK_AGENTO11Y_NODE",
            std::env::consts::OS,
            std::env::consts::ARCH
        )
    })?;
    build.fetch_into(dir)
}

/// The runtime on this machine to start the bridge with: `explicit` when set, else the first of
/// `node` on `path`, the newest nvm Node, the Homebrew and Volta ones, then Bun. A Node older than
/// [`MIN_NODE_MAJOR`] is passed over.
pub fn find_runtime(
    explicit: Option<&str>,
    path: Option<&OsStr>,
    home: Option<&Path>,
) -> Option<PathBuf> {
    if let Some(explicit) = explicit.filter(|p| !p.trim().is_empty()) {
        let explicit = PathBuf::from(explicit.trim());
        return is_usable(&explicit).then_some(explicit);
    }
    if let Some(found) = path.and_then(|path| {
        std::env::split_paths(path)
            .map(|dir| dir.join("node"))
            .find(|candidate| is_usable(candidate))
    }) {
        return Some(found);
    }
    if let Some(found) = home
        .and_then(newest_nvm_node)
        .filter(|node| is_usable(node))
    {
        return Some(found);
    }
    let mut fallbacks = vec![
        PathBuf::from("/opt/homebrew/bin/node"),
        PathBuf::from("/usr/local/bin/node"),
    ];
    if let Some(home) = home {
        fallbacks.push(home.join(".volta/bin/node"));
        fallbacks.push(home.join(".asdf/shims/node"));
        fallbacks.push(home.join(".bun/bin/bun"));
    }
    fallbacks.into_iter().find(|candidate| is_usable(candidate))
}

/// Runs, and is Bun or a Node new enough for the bridge.
fn is_usable(runtime: &Path) -> bool {
    if !is_executable(runtime) {
        return false;
    }
    let is_bun = runtime
        .file_stem()
        .and_then(OsStr::to_str)
        .is_some_and(|stem| stem.starts_with("bun"));
    is_bun || node_major(runtime).is_some_and(|major| major >= MIN_NODE_MAJOR)
}

/// The major version `node --version` prints.
fn node_major(node: &Path) -> Option<u32> {
    let output = Command::new(node)
        .arg("--version")
        .env_remove("NODE_OPTIONS")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let printed = String::from_utf8_lossy(&output.stdout);
    let (major, _, _) = parse_version(printed.trim())?;
    Some(major)
}

/// One official Node build: where it is, and what it must hash to.
pub(crate) struct NodeBuild {
    /// `node-<version>-<platform>`, the archive's top folder and the one it is unpacked as.
    name: String,
    url: String,
    sha256: String,
}

impl NodeBuild {
    /// The pinned build for this machine, from `dist` (`https://nodejs.org/dist`).
    fn pinned(dist: &str) -> Option<Self> {
        let platform = match (std::env::consts::OS, std::env::consts::ARCH) {
            ("macos", "aarch64") => "darwin-arm64",
            ("macos", "x86_64") => "darwin-x64",
            ("linux", "aarch64") => "linux-arm64",
            ("linux", "x86_64") => "linux-x64",
            _ => return None,
        };
        let (_, sha256) = NODE_SHA256.iter().find(|(p, _)| *p == platform)?;
        let name = format!("node-{NODE_VERSION}-{platform}");
        Some(Self {
            url: format!("{dist}/{NODE_VERSION}/{name}.tar.gz"),
            name,
            sha256: (*sha256).to_owned(),
        })
    }

    /// `dir/<name>/bin/node`, whether or not it is there yet.
    fn node_in(&self, dir: &Path) -> PathBuf {
        dir.join(&self.name).join("bin").join("node")
    }

    /// The build's `node` under `dir`, downloaded and unpacked first unless an earlier run did.
    /// Crok processes take turns (Crok Desktop runs one per conversation), and older builds go.
    pub(crate) fn fetch_into(&self, dir: &Path) -> Result<PathBuf, String> {
        let node = self.node_in(dir);
        if is_executable(&node) {
            return Ok(node);
        }
        let failed = |e: &dyn std::fmt::Display| {
            format!(
                "no Node.js {MIN_NODE_MAJOR}+ on this machine, and crok could not download {}: {e}",
                self.url
            )
        };
        std::fs::create_dir_all(dir).map_err(|e| failed(&e))?;
        let lock = File::create(dir.join(".node-download.lock")).map_err(|e| failed(&e))?;
        lock.lock().map_err(|e| failed(&e))?;
        if is_executable(&node) {
            return Ok(node);
        }
        // A crok that exited while unpacking left its staging folder; with the lock held, none is in use.
        remove_staging(dir);
        tracing::info!(url = %self.url, "downloading Node.js for Agent Observability");
        let mut archive = tempfile::tempfile_in(dir).map_err(|e| failed(&e))?;
        let digest = self.download(&mut archive).map_err(|e| failed(&e))?;
        if digest != self.sha256 {
            return Err(failed(&format!(
                "its SHA-256 is {digest}, not the pinned {}",
                self.sha256
            )));
        }
        archive
            .seek(io::SeekFrom::Start(0))
            .map_err(|e| failed(&e))?;
        self.unpack(archive, dir).map_err(|e| failed(&e))?;
        remove_other_builds(dir, &self.name);
        Ok(node)
    }

    /// Streams the archive into `out` and returns its SHA-256.
    fn download(&self, out: &mut File) -> Result<String, String> {
        let client = xai_grok_extra_ca::build_blocking_reqwest_client(|builder| {
            builder
                .timeout(Duration::from_secs(600))
                .connect_timeout(Duration::from_secs(15))
        })
        .map_err(|e| e.to_string())?;
        let mut response = client
            .get(&self.url)
            .send()
            .and_then(reqwest::blocking::Response::error_for_status)
            .map_err(|e| e.to_string())?;
        let mut hashing = Hashing {
            inner: out,
            hasher: Sha256::new(),
        };
        response.copy_to(&mut hashing).map_err(|e| e.to_string())?;
        hashing.inner.flush().map_err(|e| e.to_string())?;
        Ok(format!("{:x}", hashing.hasher.finalize()))
    }

    /// Unpacks `<name>/bin/node` from the archive into `dir/<name>`, replacing a partial one.
    fn unpack(&self, archive: impl Read, dir: &Path) -> io::Result<()> {
        let staging = tempfile::Builder::new().prefix(".node-").tempdir_in(dir)?;
        let wanted = Path::new(&self.name).join("bin").join("node");
        let unpacked = staging.path().join(&self.name);
        let out = unpacked.join("bin").join("node");
        let mut tar = tar::Archive::new(flate2::read::GzDecoder::new(archive));
        let mut found = false;
        for entry in tar.entries()? {
            let mut entry = entry?;
            let path: PathBuf = entry
                .path()?
                .components()
                .filter(|c| !matches!(c, Component::CurDir))
                .collect();
            if path != wanted || !entry.header().entry_type().is_file() {
                continue;
            }
            std::fs::create_dir_all(out.parent().unwrap_or(&unpacked))?;
            let mut file = File::create(&out)?;
            io::copy(&mut entry, &mut file)?;
            file.flush()?;
            found = true;
            break;
        }
        if !found {
            return Err(io::Error::other(format!(
                "the archive has no {}",
                wanted.display()
            )));
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&out, std::fs::Permissions::from_mode(0o755))?;
        }
        let target = dir.join(&self.name);
        if target.exists() {
            std::fs::remove_dir_all(&target)?;
        }
        std::fs::rename(&unpacked, &target)
    }
}

/// Removes Node builds an earlier crok downloaded into `dir`.
fn remove_other_builds(dir: &Path, keep: &str) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        if name != keep && name.starts_with("node-v") && entry.path().is_dir() {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

/// Removes the `.node-*` staging folders [`NodeBuild::unpack`] makes; call with the download lock held.
fn remove_staging(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let is_staging = entry
            .file_name()
            .to_str()
            .is_some_and(|name| name.starts_with(".node-") && name != ".node-download.lock");
        if is_staging && entry.path().is_dir() {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

/// A writer that hashes what passes through it.
struct Hashing<'a> {
    inner: &'a mut File,
    hasher: Sha256,
}

impl Write for Hashing<'_> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let written = self.inner.write(buf)?;
        self.hasher.update(buf.get(..written).unwrap_or_default());
        Ok(written)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

/// `~/.nvm/versions/node/v<major>.<minor>.<patch>/bin/node` with the highest version.
fn newest_nvm_node(home: &Path) -> Option<PathBuf> {
    let versions = home.join(".nvm/versions/node");
    std::fs::read_dir(versions)
        .ok()?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let version = parse_version(&name)?;
            let node = entry.path().join("bin/node");
            is_executable(&node).then_some((version, node))
        })
        .max_by_key(|(version, _)| *version)
        .map(|(_, node)| node)
}

fn parse_version(name: &str) -> Option<(u32, u32, u32)> {
    let mut parts = name.strip_prefix('v')?.splitn(3, '.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    Some((major, minor, patch))
}

#[cfg(unix)]
fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(path: &Path) -> bool {
    path.is_file()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// A stand-in runtime that prints `version` for `--version`.
    fn fake_runtime(path: &Path, version: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, format!("#!/bin/sh\necho {version}\n")).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn path_wins_then_the_newest_nvm_node() {
        let home = tempfile::tempdir().unwrap();
        for version in ["v16.15.0", "v22.22.0", "v20.12.0"] {
            fake_runtime(
                &home
                    .path()
                    .join(format!(".nvm/versions/node/{version}/bin/node")),
                version,
            );
        }
        let newest = home.path().join(".nvm/versions/node/v22.22.0/bin/node");
        let empty_path = std::ffi::OsString::from("/nonexistent");
        assert_eq!(
            find_runtime(None, Some(&empty_path), Some(home.path())),
            Some(newest.clone())
        );

        let on_path = home.path().join("bin/node");
        fake_runtime(&on_path, "v24.21.0");
        let path = std::env::join_paths([home.path().join("bin")]).unwrap();
        assert_eq!(
            find_runtime(None, Some(&path), Some(home.path())),
            Some(on_path.clone())
        );

        fake_runtime(&on_path, "v18.20.4");
        assert_eq!(
            find_runtime(None, Some(&path), Some(home.path())),
            Some(newest),
            "a Node too old for the bridge is passed over"
        );
    }

    #[test]
    fn an_explicit_runtime_is_used_only_when_it_runs() {
        let home = tempfile::tempdir().unwrap();
        let bun = home.path().join("tools/bun");
        fake_runtime(&bun, "1.2.3");
        assert_eq!(find_runtime(bun.to_str(), None, None), Some(bun.clone()));
        assert_eq!(
            find_runtime(Some("/nonexistent/node"), None, Some(home.path())),
            None
        );
        let dir = home.path().join("agento11y");
        assert_eq!(
            ensure_runtime(bun.to_str(), None, None, &dir),
            Ok(bun),
            "an explicit runtime needs no download"
        );
        assert!(ensure_runtime(Some("/nonexistent/node"), None, None, &dir).is_err());
        assert!(!dir.exists());
    }

    /// A `node-<version>-<platform>.tar.gz` like nodejs.org's: the binary plus other files.
    fn node_archive(name: &str) -> Vec<u8> {
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        {
            let mut tar = tar::Builder::new(&mut gz);
            let mut add = |path: String, body: &[u8], mode: u32| {
                let mut header = tar::Header::new_gnu();
                header.set_size(body.len() as u64);
                header.set_mode(mode);
                header.set_cksum();
                tar.append_data(&mut header, path, body).unwrap();
            };
            add(format!("{name}/README.md"), b"Node.js", 0o644);
            add(
                format!("{name}/bin/node"),
                b"#!/bin/sh\necho v24.21.0\n",
                0o644,
            );
            add(format!("{name}/include/node/node.h"), b"", 0o644);
            tar.finish().unwrap();
        }
        gz.finish().unwrap()
    }

    /// Serves `body` to each of `requests` GETs on a local port; returns the base URL.
    fn serve(body: Vec<u8>, requests: usize) -> String {
        use std::io::{BufRead, BufReader};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for stream in listener.incoming().take(requests) {
                let mut stream = stream.unwrap();
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                while reader.read_line(&mut line).unwrap() > 2 {
                    line.clear();
                }
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                stream.write_all(head.as_bytes()).unwrap();
                stream.write_all(&body).unwrap();
            }
        });
        url
    }

    #[test]
    fn a_download_is_used_only_when_its_hash_matches() {
        let dir = tempfile::tempdir().unwrap();
        let name = "node-v99.0.0-test-arch".to_owned();
        let archive = node_archive(&name);
        let sha256 = format!("{:x}", Sha256::digest(&archive));
        let url = format!("{}/{name}.tar.gz", serve(archive, 2));

        let tampered = NodeBuild {
            name: name.clone(),
            url: url.clone(),
            sha256: "0".repeat(64),
        };
        let err = tampered.fetch_into(dir.path()).unwrap_err();
        assert!(err.contains("not the pinned"), "{err}");
        assert!(!tampered.node_in(dir.path()).exists());

        let old = dir.path().join("node-v1.0.0-test-arch/bin/node");
        fake_runtime(&old, "v1.0.0");
        let interrupted = dir.path().join(".node-AbCd12/node-v99.0.0-test-arch/bin");
        std::fs::create_dir_all(&interrupted).unwrap();
        let build = NodeBuild { name, url, sha256 };
        let node = build.fetch_into(dir.path()).unwrap();
        assert_eq!(node, dir.path().join("node-v99.0.0-test-arch/bin/node"));
        assert!(is_usable(&node), "unpacked executable");
        assert!(!old.exists(), "older downloads go");
        assert!(
            !dir.path().join(".node-AbCd12").exists(),
            "an interrupted unpack's staging folder goes"
        );
        let leftovers: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .filter(|n| n.starts_with(".node-") && n != ".node-download.lock")
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
        // The server answered its two requests; a third would fail, and none is made.
        assert_eq!(build.fetch_into(dir.path()).unwrap(), node);
    }

    /// Downloads the real pinned build. Run with `--ignored` when NODE_VERSION or a hash changes.
    #[test]
    #[ignore = "downloads about 50 MB from nodejs.org"]
    fn the_pinned_build_downloads_and_runs() {
        let dir = tempfile::tempdir().unwrap();
        let build = NodeBuild::pinned(NODE_DIST).expect("a pinned build for this platform");
        let node = build.fetch_into(dir.path()).unwrap();
        assert_eq!(node_major(&node), Some(24));
    }
}
