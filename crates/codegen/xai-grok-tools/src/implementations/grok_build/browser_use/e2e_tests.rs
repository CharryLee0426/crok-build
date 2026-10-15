//! The browser tool against a real browser: `cargo test -p xai-grok-tools browser_e2e -- --ignored`.
//! Starts a headless Chromium-based browser on a scratch profile and a page served on loopback.

use std::path::PathBuf;

use super::session::BrowserSession;
use super::{BrowserAction, BrowserInput, BrowserParams, ReadPageFilter, ScrollDirection};

const PAGE: &str = r#"<!doctype html><html><head><title>Crok test</title></head><body>
<h1>Hello</h1>
<label for="name">Name</label> <input id="name" placeholder="Your name">
<select id="color"><option value="r">Red</option><option value="g">Green</option></select>
<input type="checkbox" id="agree"><label for="agree">Agree</label>
<button id="go" onclick="document.getElementById('out').textContent = 'Hi ' + document.getElementById('name').value; console.log('greeted', document.getElementById('name').value)">Greet</button>
<p id="out"></p>
<a href="/next">Next page</a>
<a href="/next" target="_blank">Open in new tab</a>
</body></html>"#;

const NEXT: &str = "<!doctype html><html><head><title>Next</title></head><body><main><p>The second page.</p></main></body></html>";

async fn serve() -> String {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 4096];
                let read = stream.read(&mut buffer).await.unwrap_or(0);
                let request = String::from_utf8_lossy(&buffer[..read]);
                let body = if request.starts_with("GET /next") {
                    NEXT
                } else {
                    PAGE
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes()).await;
            });
        }
    });
    format!("http://{address}/")
}

fn input(action: BrowserAction) -> BrowserInput {
    BrowserInput::new(action)
}

fn reference(tree: &str, line_start: &str) -> String {
    let line = tree
        .lines()
        .find(|line| line.trim_start().starts_with(line_start))
        .unwrap_or_else(|| panic!("no line starting {line_start:?} in:\n{tree}"));
    let start = line.find("[ref_").expect("a reference") + 1;
    let end = line[start..].find(']').unwrap() + start;
    line[start..end].to_owned()
}

#[tokio::test]
#[ignore = "starts a real browser"]
async fn browser_e2e_drives_a_real_page() {
    let profile = tempfile::tempdir().unwrap();
    let params = BrowserParams {
        headless: true,
        profile_dir: Some(profile.path().to_path_buf()),
        ..BrowserParams::default()
    };
    let session = BrowserSession::new_for_tests(params, PathBuf::from("."));
    let url = serve().await;

    let mut go = input(BrowserAction::Navigate);
    go.url = Some(url.clone());
    let navigated = session.run(None, go).await;
    assert!(!navigated.is_error, "{}", navigated.text);
    assert!(
        navigated.text.contains("Navigated to http://127.0.0.1"),
        "{}",
        navigated.text
    );
    assert!(
        navigated.text.contains("Crok test") && navigated.text.contains("(HTTP 200)"),
        "{}",
        navigated.text
    );
    assert!(
        navigated.text.contains("Tab Context:"),
        "{}",
        navigated.text
    );

    let tree = session.run(None, input(BrowserAction::ReadPage)).await;
    assert!(!tree.is_error, "{}", tree.text);
    assert!(tree.text.contains("heading \"Hello\""), "{}", tree.text);
    let name = reference(&tree.text, "textbox \"Name\"");
    let greet = reference(&tree.text, "button \"Greet\"");
    let color = reference(&tree.text, "combobox");
    let agree = reference(&tree.text, "checkbox \"Agree\"");

    let mut find = input(BrowserAction::Find);
    find.query = Some("name field".into());
    let found = session.run(None, find).await;
    assert!(found.text.contains(&format!("[{name}]")), "{}", found.text);

    let mut click = input(BrowserAction::LeftClick);
    click.element_ref = Some(name.clone());
    assert_eq!(session.run(None, click).await.text, "Clicked.");
    let mut typed = input(BrowserAction::Type);
    typed.text = Some("Ada Lovelace".into());
    assert_eq!(session.run(None, typed).await.text, "Typed.");
    let mut press = input(BrowserAction::LeftClick);
    press.element_ref = Some(greet);
    assert!(!session.run(None, press).await.is_error);
    let text = session.run(None, input(BrowserAction::GetPageText)).await;
    assert!(text.text.contains("Hi Ada Lovelace"), "{}", text.text);

    let mut select = input(BrowserAction::FormInput);
    select.element_ref = Some(color);
    select.value = Some(serde_json::json!("Green"));
    assert!(!session.run(None, select).await.is_error);
    let mut check = input(BrowserAction::FormInput);
    check.element_ref = Some(agree);
    check.value = Some(serde_json::json!(true));
    assert!(!session.run(None, check).await.is_error);
    let mut interactive = input(BrowserAction::ReadPage);
    interactive.filter = Some(ReadPageFilter::Interactive);
    let after = session.run(None, interactive).await.text;
    assert!(after.contains("value=\"Green\""), "{after}");
    assert!(
        after.contains("checkbox \"Agree\"") && after.contains(" checked"),
        "{after}"
    );
    assert!(
        !after.contains("heading"),
        "interactive leaves out headings: {after}"
    );

    let shot = session.run(None, input(BrowserAction::Screenshot)).await;
    let image = shot.image.expect("a screenshot");
    assert!(image.data.len() > 1000);
    let mut zoom = input(BrowserAction::Zoom);
    zoom.region = Some([0.0, 0.0, 200.0, 100.0]);
    let zoomed = session.run(None, zoom).await;
    assert!(zoomed.image.is_some(), "{}", zoomed.text);

    let mut script = input(BrowserAction::JavascriptExec);
    script.text = Some("document.title + ' ' + (1 + 1)".into());
    assert_eq!(session.run(None, script).await.text, "Crok test 2");

    let console = session.run(None, input(BrowserAction::ReadConsole)).await;
    assert!(
        console.text.contains("greeted Ada Lovelace"),
        "{}",
        console.text
    );
    let network = session.run(None, input(BrowserAction::ReadNetwork)).await;
    assert!(
        network.text.contains("GET http://127.0.0.1"),
        "{}",
        network.text
    );

    let mut scroll = input(BrowserAction::Scroll);
    scroll.scroll_direction = Some(ScrollDirection::Down);
    assert_eq!(session.run(None, scroll).await.text, "Scrolled down.");
    let mut key = input(BrowserAction::Key);
    key.text = Some("Tab".into());
    assert_eq!(session.run(None, key).await.text, "Pressed Tab.");

    let links = session.run(None, input(BrowserAction::ReadPage)).await.text;
    let popup = reference(&links, "link \"Open in new tab\"");
    let mut open = input(BrowserAction::LeftClick);
    open.element_ref = Some(popup);
    let opened = session.run(None, open).await;
    assert!(
        opened.text.contains("A new tab opened: tab-2."),
        "{}",
        opened.text
    );
    let tabs = session.run(None, input(BrowserAction::ListTabs)).await.text;
    assert!(
        tabs.starts_with("Available tabs:") && tabs.contains("tab-2"),
        "{tabs}"
    );
    let mut switch = input(BrowserAction::SwitchTab);
    switch.tab_id = Some("tab-1".into());
    assert_eq!(
        session.run(None, switch).await.text,
        "Switched to tab tab-1"
    );
    let mut close = input(BrowserAction::CloseTab);
    close.tab_id = Some("tab-2".into());
    assert_eq!(session.run(None, close).await.text, "Closed tab tab-2");

    let mut next = input(BrowserAction::Navigate);
    next.url = Some(format!("{url}next"));
    assert!(session.run(None, next).await.text.contains("Next"));
    let mut stale = input(BrowserAction::LeftClick);
    stale.element_ref = Some(name);
    let stale_click = session.run(None, stale).await;
    assert!(
        stale_click.is_error && stale_click.text.contains("is stale"),
        "{}",
        stale_click.text
    );
    let mut back = input(BrowserAction::Navigate);
    back.url = Some("back".into());
    let went_back = session.run(None, back).await;
    assert!(went_back.text.contains("Crok test"), "{}", went_back.text);

    let mut refused = input(BrowserAction::Navigate);
    refused.url = Some("javascript:alert(1)".into());
    let refused = session.run(Some(7), refused).await;
    assert!(
        refused.is_error && refused.text.contains("Only http and https"),
        "{}",
        refused.text
    );
    let skipped = session.run(Some(7), input(BrowserAction::Screenshot)).await;
    assert_eq!(
        skipped.text,
        crate::implementations::grok_build::device_use::BROWSER_HALT_TEXT
    );
    assert!(
        !session
            .run(Some(8), input(BrowserAction::ListTabs))
            .await
            .is_error
    );

    session.quit().await;
}
