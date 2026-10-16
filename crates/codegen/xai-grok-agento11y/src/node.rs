//! Finding a JavaScript runtime for the bridge.
//!
//! Crok Desktop starts from Finder with launchd's short PATH (plus Homebrew's), so a Node
//! installed by nvm is not on it: the usual install places are searched too.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

/// The runtime to start the bridge with: `explicit` (`CROK_AGENTO11Y_NODE`) when set, else the
/// first of `node` on `path`, the newest nvm Node, the Homebrew and Volta ones, then Bun.
pub fn find_runtime(
    explicit: Option<&str>,
    path: Option<&OsStr>,
    home: Option<&Path>,
) -> Option<PathBuf> {
    if let Some(explicit) = explicit.filter(|p| !p.trim().is_empty()) {
        let explicit = PathBuf::from(explicit.trim());
        return is_executable(&explicit).then_some(explicit);
    }
    if let Some(found) = path.and_then(|path| {
        std::env::split_paths(path)
            .map(|dir| dir.join("node"))
            .find(|candidate| is_executable(candidate))
    }) {
        return Some(found);
    }
    if let Some(found) = home.and_then(newest_nvm_node) {
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
    fallbacks
        .into_iter()
        .find(|candidate| is_executable(candidate))
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

    fn fake_executable(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[test]
    fn path_wins_then_the_newest_nvm_node() {
        let home = tempfile::tempdir().unwrap();
        for version in ["v16.15.0", "v22.22.0", "v20.12.0"] {
            fake_executable(
                &home
                    .path()
                    .join(format!(".nvm/versions/node/{version}/bin/node")),
            );
        }
        let newest = home.path().join(".nvm/versions/node/v22.22.0/bin/node");
        let empty_path = std::ffi::OsString::from("/nonexistent");
        assert_eq!(
            find_runtime(None, Some(&empty_path), Some(home.path())),
            Some(newest)
        );

        let on_path = home.path().join("bin/node");
        fake_executable(&on_path);
        let path = std::env::join_paths([home.path().join("bin")]).unwrap();
        assert_eq!(
            find_runtime(None, Some(&path), Some(home.path())),
            Some(on_path)
        );
    }

    #[test]
    fn an_explicit_runtime_is_used_only_when_it_runs() {
        let home = tempfile::tempdir().unwrap();
        let bun = home.path().join("tools/bun");
        fake_executable(&bun);
        assert_eq!(find_runtime(bun.to_str(), None, None), Some(bun));
        assert_eq!(
            find_runtime(Some("/nonexistent/node"), None, Some(home.path())),
            None
        );
    }
}
