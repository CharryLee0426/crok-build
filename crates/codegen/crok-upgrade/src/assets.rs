//! Which file in a release this installation needs, and where it goes.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

/// What `crok upgrade` replaces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// This crok is `Contents/Resources/crok` inside a Crok Desktop bundle: the whole app is
    /// replaced, which carries the TUI with it.
    App { bundle: PathBuf },
    /// A standalone `crok` binary (for example `~/.local/bin/crok` from `make deploy`).
    Binary { path: PathBuf },
}

impl Target {
    pub fn path(&self) -> &Path {
        match self {
            Target::App { bundle } => bundle,
            Target::Binary { path } => path,
        }
    }

    pub fn kind(&self) -> &'static str {
        match self {
            Target::App { .. } => "app",
            Target::Binary { .. } => "binary",
        }
    }
}

/// Classifies the running executable. `CROK_UPGRADE_TARGET` names another bundle or binary to
/// upgrade instead, which the tests and the release check use.
pub fn detect_target(exe: &Path) -> Result<Target> {
    if let Some(forced) = std::env::var_os("CROK_UPGRADE_TARGET").filter(|v| !v.is_empty()) {
        let forced = dunce::canonicalize(&forced)
            .with_context(|| format!("CROK_UPGRADE_TARGET {}", Path::new(&forced).display()))?;
        return Ok(if forced.extension().is_some_and(|ext| ext == "app") {
            Target::App { bundle: forced }
        } else {
            Target::Binary { path: forced }
        });
    }
    let exe = dunce::canonicalize(exe).with_context(|| format!("locating {}", exe.display()))?;
    Ok(classify(&exe))
}

fn classify(exe: &Path) -> Target {
    // <bundle>.app/Contents/Resources/crok
    if exe.file_name().is_some_and(|name| name == "crok")
        && let Some(resources) = exe.parent()
        && resources.file_name().is_some_and(|name| name == "Resources")
        && let Some(contents) = resources.parent()
        && contents.file_name().is_some_and(|name| name == "Contents")
        && let Some(bundle) = contents.parent()
        && bundle.extension().is_some_and(|ext| ext == "app")
    {
        return Target::App {
            bundle: bundle.to_path_buf(),
        };
    }
    Target::Binary {
        path: exe.to_path_buf(),
    }
}

/// Refuses targets an upgrade must not touch.
pub fn check_target(target: &Target) -> Result<()> {
    let path = target.path();
    if path
        .components()
        .any(|component| component.as_os_str() == "target")
        && path.ancestors().any(|dir| dir.join("Cargo.toml").is_file())
    {
        bail!(
            "{} is a build in a source checkout. Upgrade a source build with `git pull` and `make deploy`.",
            path.display()
        );
    }
    if path.to_string_lossy().contains("/AppTranslocation/") {
        bail!("Crok Desktop runs from a translocated copy. Move it to Applications and open it again.");
    }
    let parent = path
        .parent()
        .with_context(|| format!("{} has no parent folder", path.display()))?;
    let probe = tempfile::Builder::new()
        .prefix(".crok-upgrade-")
        .tempfile_in(parent);
    if probe.is_err() {
        bail!(
            "{} is not writable, so the upgrade cannot replace {}",
            parent.display(),
            path.display()
        );
    }
    Ok(())
}

/// `arm64` or `x86_64`, as the release file names spell it.
pub fn arch_label() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "arm64",
        other => other,
    }
}

/// Which of a release's two disk images a copy of Crok Desktop takes. Liquid Glass needs an app
/// built with the macOS 26 SDK, so a release carries one image per SDK, and an installed copy
/// stays on the SDK it was built with whatever macOS it runs on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskImage {
    MacOS26Sdk,
    MacOS15Sdk,
}

impl DiskImage {
    /// The image for an app linked against SDK `major`. A newer toolchain stamps a macOS 26 SDK
    /// build as 27 or later, the way `release/publish.sh` accepts it.
    pub fn for_linked_sdk(major: u32) -> Self {
        if major >= 26 {
            Self::MacOS26Sdk
        } else {
            Self::MacOS15Sdk
        }
    }

    /// `26` or `15`, as the image names spell it.
    pub fn sdk(self) -> u32 {
        match self {
            Self::MacOS26Sdk => 26,
            Self::MacOS15Sdk => 15,
        }
    }
}

/// The disk image a copy built against `image`'s SDK installs.
pub fn app_asset_name(version: &semver::Version, arch: &str, image: DiskImage) -> String {
    format!("Crok-Desktop-{version}-{arch}-macOS{}-SDK.dmg", image.sdk())
}

/// The macOS SDK (major, minor) the app in `bundle` was linked against, from its executable.
pub fn app_linked_sdk(bundle: &Path) -> Result<(u32, u32)> {
    let name = crate::install::plist_value(bundle, "CFBundleExecutable")
        .with_context(|| format!("{} names no executable", bundle.display()))?;
    let executable = bundle.join("Contents/MacOS").join(name);
    linked_sdk(&executable).with_context(|| format!("reading the SDK version of {}", executable.display()))
}

const MH_MAGIC_64: u32 = 0xfeed_facf;
const MH_MAGIC: u32 = 0xfeed_face;
const FAT_MAGIC: u32 = 0xcafe_babe;
const FAT_MAGIC_64: u32 = 0xcafe_babf;
const LC_VERSION_MIN_MACOSX: u32 = 0x24;
const LC_BUILD_VERSION: u32 = 0x32;
const CPU_TYPE_ARM64: u32 = 0x0100_000c;
const CPU_TYPE_X86_64: u32 = 0x0100_0007;

/// The SDK a Mach-O executable was linked against: `LC_BUILD_VERSION` (or the older
/// `LC_VERSION_MIN_MACOSX`) of the slice for this machine.
pub fn linked_sdk(executable: &Path) -> Result<(u32, u32)> {
    let bytes = std::fs::read(executable)?;
    let slice = mach_slice(&bytes).context("not a Mach-O executable")?;
    let sdk = sdk_of_slice(slice).context("no LC_BUILD_VERSION")?;
    Ok((sdk >> 16, (sdk >> 8) & 0xff))
}

fn read_u32(bytes: &[u8], offset: usize, big_endian: bool) -> Option<u32> {
    let word: [u8; 4] = bytes.get(offset..offset.checked_add(4)?)?.try_into().ok()?;
    Some(if big_endian { u32::from_be_bytes(word) } else { u32::from_le_bytes(word) })
}

fn read_u64_be(bytes: &[u8], offset: usize) -> Option<u64> {
    let word: [u8; 8] = bytes.get(offset..offset.checked_add(8)?)?.try_into().ok()?;
    Some(u64::from_be_bytes(word))
}

/// The thin Mach-O inside `bytes`: the file itself, or this machine's slice of a universal one.
fn mach_slice(bytes: &[u8]) -> Option<&[u8]> {
    let magic = read_u32(bytes, 0, true)?;
    if magic != FAT_MAGIC && magic != FAT_MAGIC_64 {
        return Some(bytes);
    }
    let wanted = if cfg!(target_arch = "x86_64") { CPU_TYPE_X86_64 } else { CPU_TYPE_ARM64 };
    let count = read_u32(bytes, 4, true)? as usize;
    let (entry_size, wide) = if magic == FAT_MAGIC_64 { (32, true) } else { (20, false) };
    let mut slices = Vec::new();
    for index in 0..count.min(16) {
        let entry = 8 + index * entry_size;
        let cpu = read_u32(bytes, entry, true)?;
        let (offset, size) = if wide {
            (read_u64_be(bytes, entry + 8)? as usize, read_u64_be(bytes, entry + 16)? as usize)
        } else {
            (read_u32(bytes, entry + 8, true)? as usize, read_u32(bytes, entry + 12, true)? as usize)
        };
        slices.push((cpu, bytes.get(offset..offset.checked_add(size)?)?));
    }
    slices
        .iter()
        .find(|(cpu, _)| *cpu == wanted)
        .or_else(|| slices.first())
        .map(|(_, slice)| *slice)
}

fn sdk_of_slice(slice: &[u8]) -> Option<u32> {
    let header = match read_u32(slice, 0, false)? {
        MH_MAGIC_64 => 32,
        MH_MAGIC => 28,
        _ => return None,
    };
    let count = read_u32(slice, 16, false)?;
    let mut offset = header;
    let mut older = None;
    for _ in 0..count {
        let command = read_u32(slice, offset, false)?;
        let size = read_u32(slice, offset + 4, false)? as usize;
        match command {
            // build_version_command: cmd, cmdsize, platform, minos, sdk, ntools
            LC_BUILD_VERSION => return read_u32(slice, offset + 16, false),
            // version_min_command: cmd, cmdsize, version, sdk
            LC_VERSION_MIN_MACOSX => older = read_u32(slice, offset + 12, false),
            _ => {}
        }
        if size < 8 {
            return older;
        }
        offset = offset.checked_add(size)?;
    }
    older
}

/// The standalone TUI tarball for this platform, when releases carry one.
pub fn binary_asset_name(version: &semver::Version, arch: &str) -> Option<String> {
    let platform = match std::env::consts::OS {
        "macos" => "apple-darwin",
        "linux" => "unknown-linux-gnu",
        _ => return None,
    };
    let arch = if arch == "arm64" { "aarch64" } else { arch };
    Some(format!("crok-{version}-{arch}-{platform}.tar.gz"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_harness_is_an_app_target() {
        let exe = Path::new("/Applications/Crok Desktop.app/Contents/Resources/crok");
        assert_eq!(
            classify(exe),
            Target::App {
                bundle: PathBuf::from("/Applications/Crok Desktop.app")
            }
        );
        let exe = Path::new("/Users/me/.local/bin/crok");
        assert_eq!(
            classify(exe),
            Target::Binary {
                path: exe.to_path_buf()
            }
        );
        let exe = Path::new("/Applications/Crok Desktop.app/Contents/Resources/bin/crok");
        assert!(matches!(classify(exe), Target::Binary { .. }));
    }

    #[test]
    fn asset_names_follow_the_linked_sdk() {
        let version = semver::Version::new(1, 5, 0);
        assert_eq!(
            app_asset_name(&version, "arm64", DiskImage::for_linked_sdk(26)),
            "Crok-Desktop-1.5.0-arm64-macOS26-SDK.dmg"
        );
        assert_eq!(
            app_asset_name(&version, "arm64", DiskImage::for_linked_sdk(27)),
            "Crok-Desktop-1.5.0-arm64-macOS26-SDK.dmg"
        );
        assert_eq!(
            app_asset_name(&version, "arm64", DiskImage::for_linked_sdk(15)),
            "Crok-Desktop-1.5.0-arm64-macOS15-SDK.dmg"
        );
        assert_eq!(
            app_asset_name(&version, "arm64", DiskImage::for_linked_sdk(14)),
            "Crok-Desktop-1.5.0-arm64-macOS15-SDK.dmg"
        );
        if cfg!(target_os = "macos") {
            assert_eq!(
                binary_asset_name(&version, "arm64").unwrap(),
                "crok-1.5.0-aarch64-apple-darwin.tar.gz"
            );
        }
    }

    /// A thin 64-bit Mach-O with a segment command and then `LC_BUILD_VERSION`.
    fn thin_macho(cpu: u32, sdk: (u32, u32)) -> Vec<u8> {
        let mut out = Vec::new();
        let segment_size = 72u32;
        let build_size = 24u32;
        for word in [MH_MAGIC_64, cpu, 0, 2, 2, segment_size + build_size, 0, 0] {
            out.extend_from_slice(&word.to_le_bytes());
        }
        out.extend_from_slice(&0x19u32.to_le_bytes()); // LC_SEGMENT_64
        out.extend_from_slice(&segment_size.to_le_bytes());
        out.extend(std::iter::repeat_n(0u8, segment_size as usize - 8));
        let encoded = (sdk.0 << 16) | (sdk.1 << 8);
        for word in [LC_BUILD_VERSION, build_size, 1, 14 << 16, encoded, 0] {
            out.extend_from_slice(&word.to_le_bytes());
        }
        out
    }

    fn universal(slices: &[(u32, Vec<u8>)]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&FAT_MAGIC.to_be_bytes());
        out.extend_from_slice(&(slices.len() as u32).to_be_bytes());
        let mut offset = 4096u32;
        let mut bodies = Vec::new();
        for (cpu, body) in slices {
            for word in [*cpu, 0, offset, body.len() as u32, 12] {
                out.extend_from_slice(&word.to_be_bytes());
            }
            bodies.push((offset, body));
            offset += 4096 * (1 + body.len() as u32 / 4096);
        }
        for (at, body) in bodies {
            out.resize(at as usize, 0);
            out.extend_from_slice(body);
        }
        out
    }

    #[test]
    fn linked_sdk_reads_thin_and_universal_executables() {
        let dir = tempfile::tempdir().unwrap();
        let thin = dir.path().join("thin");
        std::fs::write(&thin, thin_macho(CPU_TYPE_ARM64, (26, 0))).unwrap();
        assert_eq!(linked_sdk(&thin).unwrap(), (26, 0));

        let fat = dir.path().join("fat");
        std::fs::write(
            &fat,
            universal(&[
                (CPU_TYPE_X86_64, thin_macho(CPU_TYPE_X86_64, (15, 4))),
                (CPU_TYPE_ARM64, thin_macho(CPU_TYPE_ARM64, (26, 2))),
            ]),
        )
        .unwrap();
        let expected = if cfg!(target_arch = "x86_64") { (15, 4) } else { (26, 2) };
        assert_eq!(linked_sdk(&fat).unwrap(), expected);

        let text = dir.path().join("script");
        std::fs::write(&text, b"#!/bin/sh\necho hi\n").unwrap();
        assert!(linked_sdk(&text).is_err());
    }

    #[test]
    fn an_app_takes_the_image_of_the_sdk_it_was_built_with() {
        if !cfg!(target_os = "macos") {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        for (sdk, image) in [((15, 4), DiskImage::MacOS15Sdk), ((26, 0), DiskImage::MacOS26Sdk)] {
            let bundle = dir.path().join(format!("Crok Desktop {}.app", sdk.0));
            std::fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
            std::fs::write(
                bundle.join("Contents/Info.plist"),
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
                 <key>CFBundleExecutable</key><string>GrokDesktop</string></dict></plist>\n",
            )
            .unwrap();
            std::fs::write(bundle.join("Contents/MacOS/GrokDesktop"), thin_macho(CPU_TYPE_ARM64, sdk)).unwrap();
            assert_eq!(app_linked_sdk(&bundle).unwrap(), sdk);
            assert_eq!(DiskImage::for_linked_sdk(sdk.0), image);
        }
        // This test binary itself was linked against some macOS SDK.
        let own = linked_sdk(&std::env::current_exe().unwrap()).unwrap();
        assert!(own.0 >= 11, "{own:?}");
    }

    #[test]
    fn source_builds_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("Cargo.toml"), "[workspace]\n").unwrap();
        let exe = dir.path().join("target/release/xai-grok-pager");
        std::fs::create_dir_all(exe.parent().unwrap()).unwrap();
        std::fs::write(&exe, b"").unwrap();
        let error = check_target(&Target::Binary { path: exe }).unwrap_err();
        assert!(error.to_string().contains("source checkout"), "{error}");

        let plain = dir.path().join("bin/crok");
        std::fs::create_dir_all(plain.parent().unwrap()).unwrap();
        std::fs::write(&plain, b"").unwrap();
        check_target(&Target::Binary { path: plain }).unwrap();
    }
}
