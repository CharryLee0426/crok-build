//! End-to-end checks against the real machine, run by hand:
//! `cargo test -p xai-grok-tools --lib phone_use::e2e_tests -- --ignored --nocapture`.
//!
//! They need the network (the Platform-Tools download), and for the phone checks a paired
//! iPhone Mirroring or an Android phone with USB debugging allowed.

use super::session::PhoneSession;
use super::{PhoneAction, PhoneDevice, PhoneInput};

#[tokio::test]
#[ignore = "downloads Google's Android platform-tools"]
async fn downloads_platform_tools_and_runs_adb() {
    let dir = tempfile::tempdir().unwrap();
    let adb = super::adb::download_into(dir.path().to_path_buf())
        .await
        .expect("download");
    let out = super::adb::run(&adb, None, &["version"], std::time::Duration::from_secs(30))
        .await
        .expect("adb runs");
    println!("{}", out.text());
    assert!(out.success);
    assert!(out.text().contains("Android Debug Bridge"));
}

#[cfg(target_os = "macos")]
#[test]
#[ignore = "prints iPhone Mirroring's windows"]
fn lists_mirroring_windows() {
    use super::macos::{Ax, pid_under, windows};
    let pid = pid_under("/System/Applications/iPhone Mirroring.app/Contents/").expect("running");
    println!("pid {pid}");
    for on_screen in [true, false] {
        for w in windows(on_screen).into_iter().filter(|w| w.pid == pid) {
            println!("on_screen={on_screen} {w:?}");
        }
    }
    let app = Ax::application(pid).expect("ax");
    println!("frontmost {:?}", app.boolean("AXFrontmost"));
    for w in app.elements("AXWindows") {
        println!(
            "ax window {:?} {:?} {:?}",
            w.string("AXTitle"),
            w.frame(),
            w.string("AXRole")
        );
        for c in w.elements("AXChildren") {
            println!(
                "  child {:?} {:?} {:?}",
                c.string("AXRole"),
                c.string("AXTitle"),
                c.frame()
            );
        }
    }
}

#[tokio::test]
#[ignore = "reads this Mac's phones"]
async fn reports_status() {
    let session = PhoneSession::default();
    let result = session
        .run(None, PhoneInput::new(PhoneAction::Status))
        .await;
    println!("{}", result.text);
    assert!(!result.is_error);
}

#[tokio::test]
#[ignore = "drives a real phone: PHONE_E2E_DEVICE=iphone|android"]
async fn connects_reads_and_looks() {
    let device = match std::env::var("PHONE_E2E_DEVICE").as_deref() {
        Ok("android") => PhoneDevice::Android,
        _ => PhoneDevice::Iphone,
    };
    let session = PhoneSession::default();
    for action in [
        PhoneAction::Connect,
        PhoneAction::ReadScreen,
        PhoneAction::Screenshot,
    ] {
        let mut input = PhoneInput::new(action);
        input.device = Some(device);
        let result = session.run(None, input).await;
        println!(
            "--- {} ({})\n{}",
            action.name(),
            if result.is_error { "error" } else { "ok" },
            result.text
        );
        if let Some(image) = &result.image {
            println!("image {} bytes base64 {:?}", image.data.len(), image.meta);
            if let Ok(dir) = std::env::var("PHONE_E2E_SAVE") {
                use base64::Engine as _;
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(&image.data)
                    .unwrap();
                let extension = if image.mime_type.contains("png") {
                    "png"
                } else {
                    "jpg"
                };
                let path = std::path::Path::new(&dir).join(format!("phone.{extension}"));
                std::fs::write(&path, bytes).unwrap();
                println!("saved {}", path.display());
            }
        }
        if result.is_error {
            break;
        }
    }
}
