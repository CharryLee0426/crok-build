//! One Crok session's hold on the browser: its tabs, what they reported, and every action.
//!
//! A session owns the tabs it opened and the tabs those pages opened; other sessions sharing the
//! browser never see them. Actions run one at a time. Events (console lines, requests, dialogs,
//! downloads, tabs a page opens) are collected in the background and reported with the next
//! successful result, as the toolset reports state changes.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Weak};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};
use tokio::sync::broadcast;
use tokio::sync::broadcast::error::RecvError;
use tokio::time::Instant;

use super::cdp::{CdpConnection, CdpError, CdpEvent};
use super::keys::{self, Chord};
use super::launch;
use super::{BrowserAction, BrowserInput, BrowserParams, ReadPageFilter};
use crate::implementations::grok_build::device_use::screenshot::{self, FittedImage, Scale};
use crate::implementations::grok_build::device_use::{
    BROWSER_HALT_TEXT, BatchHalt, ConfirmationFields, DeviceActionResult, Modifiers, TabSummary,
    capped_result_text, checked_duration, fill_confirmation, one_line, truncate_chars,
};

const PAGE_SCRIPT: &str = include_str!("page_script.js");
const LOAD_TIMEOUT: Duration = Duration::from_secs(20);
const SETTLE_WINDOW: Duration = Duration::from_millis(250);
const SETTLE_LOAD_TIMEOUT: Duration = Duration::from_secs(10);
const BUFFER_LIMIT: usize = 1000;
const ENTRY_CHARS: usize = 500;
const MAX_WAIT_SECS: f64 = 30.0;
const MAX_UPLOAD_BYTES: u64 = 10 * 1024 * 1024;
const TAB_MISSING: &str = "The tab this call was addressed to is not open; nothing was returned. Use list_tabs to see what is open.";

static NULL: Value = Value::Null;

/// The value at a JSON pointer such as `/targetInfo/url`; null when any part is missing, as indexing reads.
fn at<'a>(value: &'a Value, pointer: &str) -> &'a Value {
    value.pointer(pointer).unwrap_or(&NULL)
}

/// The browser as a session's `Resources` hold it.
#[derive(Clone)]
pub struct BrowserSessionHandle(pub Arc<BrowserSession>);

static SESSIONS: LazyLock<parking_lot::Mutex<HashMap<String, Weak<BrowserSession>>>> =
    LazyLock::new(Default::default);

impl BrowserSessionHandle {
    /// The browser session for the Crok session `key`. Every agent built for that session shares
    /// it, so switching models mid-task keeps the tabs.
    pub fn for_session(key: &str, params: BrowserParams, cwd: PathBuf) -> Self {
        let mut sessions = SESSIONS.lock();
        sessions.retain(|_, session| session.strong_count() > 0);
        if let Some(existing) = sessions.get(key).and_then(Weak::upgrade)
            && existing.params == params
        {
            return Self(existing);
        }
        let session = Arc::new(BrowserSession::new(params, cwd));
        sessions.insert(key.to_owned(), Arc::downgrade(&session));
        Self(session)
    }
}

pub struct BrowserSession {
    params: BrowserParams,
    cwd: PathBuf,
    halt: BatchHalt,
    inner: tokio::sync::Mutex<Inner>,
    shared: Arc<parking_lot::Mutex<Shared>>,
}

#[derive(Default)]
struct Inner {
    connection: Option<Arc<CdpConnection>>,
    pump: Option<tokio::task::JoinHandle<()>>,
    window_opened: bool,
    /// The tab inventory last shown to the model, so an unchanged one is not repeated.
    reported: Option<String>,
}

#[derive(Default)]
struct Shared {
    tabs: Vec<Tab>,
    active: Option<String>,
    next_tab: u32,
    changes: Vec<Change>,
    dialogs: Vec<(String, String)>,
    downloads: HashMap<String, Download>,
    next_download: u32,
    download_dir: PathBuf,
    /// Pages our tabs opened, not yet attached.
    popups: Vec<String>,
}

struct Tab {
    id: String,
    target_id: String,
    session_id: String,
    title: String,
    url: String,
    console: VecDeque<String>,
    network: VecDeque<String>,
    requests: HashMap<String, Request>,
    scale: Option<Scale>,
    next_ref: u64,
    world: Option<i64>,
    mouse_down: bool,
}

struct Request {
    method: String,
    url: String,
    started: f64,
    status: Option<u64>,
    mime: Option<String>,
}

struct Download {
    id: String,
    url: String,
    suggested: String,
}

enum Change {
    TabOpened(String),
    DownloadStarted {
        id: String,
        url: String,
    },
    DownloadCompleted {
        id: String,
        url: String,
        path: Option<String>,
        size: Option<u64>,
    },
    DownloadFailed {
        id: String,
        url: String,
        error: String,
    },
}

/// The ids of one tab, copied out so no lock is held across a command.
#[derive(Debug, Clone)]
struct TabRef {
    id: String,
    target_id: String,
    session_id: String,
}

/// What an action produced before the session adds its reports.
struct Done {
    text: String,
    image: Option<FittedImage>,
    executed_on: Option<String>,
    /// A tab-management result: its text already says what the tabs are.
    renders_tabs: bool,
}

impl Done {
    fn on(text: impl Into<String>, tab: &TabRef) -> Self {
        Self {
            text: text.into(),
            image: None,
            executed_on: Some(tab.id.clone()),
            renders_tabs: false,
        }
    }

    fn tabs(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            image: None,
            executed_on: None,
            renders_tabs: true,
        }
    }

    fn with_image(mut self, image: FittedImage) -> Self {
        self.image = Some(image);
        self
    }
}

struct Loaded {
    loaded: bool,
    status: Option<u64>,
}

impl Shared {
    fn tab(&self, id: &str) -> Option<&Tab> {
        self.tabs.iter().find(|tab| tab.id == id)
    }

    fn tab_mut(&mut self, id: &str) -> Option<&mut Tab> {
        self.tabs.iter_mut().find(|tab| tab.id == id)
    }

    fn tab_ref(&self, id: &str) -> Option<TabRef> {
        self.tab(id).map(Tab::to_ref)
    }

    fn active_ref(&self) -> Option<TabRef> {
        self.active.as_deref().and_then(|id| self.tab_ref(id))
    }

    fn by_session_mut(&mut self, session_id: &str) -> Option<&mut Tab> {
        self.tabs
            .iter_mut()
            .find(|tab| tab.session_id == session_id)
    }

    fn remove_tab(&mut self, matches: impl Fn(&Tab) -> bool) {
        let before = self.tabs.len();
        self.tabs.retain(|tab| !matches(tab));
        if self.tabs.len() != before
            && self
                .active
                .as_deref()
                .is_none_or(|active| self.tab(active).is_none())
        {
            self.active = self.tabs.last().map(|tab| tab.id.clone());
        }
    }

    /// One line per open tab, as the API renders a `browser_state` block's `tabs`.
    fn inventory(&self, mark_current: bool) -> String {
        self.tabs
            .iter()
            .map(|tab| {
                let current = mark_current && self.active.as_deref() == Some(tab.id.as_str());
                format!(
                    "  • tab_id {}: \"{}\" ({}){}",
                    tab.id,
                    escape_title(&tab.title),
                    truncate_chars(&one_line(&tab.url), 500),
                    if current { " (current)" } else { "" }
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

impl Tab {
    fn new(id: String, target_id: &str, session_id: String) -> Self {
        Self {
            id,
            target_id: target_id.to_owned(),
            session_id,
            title: String::new(),
            url: "about:blank".to_owned(),
            console: VecDeque::new(),
            network: VecDeque::new(),
            requests: HashMap::new(),
            scale: None,
            next_ref: 1,
            world: None,
            mouse_down: false,
        }
    }

    fn to_ref(&self) -> TabRef {
        TabRef {
            id: self.id.clone(),
            target_id: self.target_id.clone(),
            session_id: self.session_id.clone(),
        }
    }

    fn summary(&self) -> TabSummary {
        TabSummary {
            tab_id: self.id.clone(),
            title: one_line(&self.title),
            url: one_line(&self.url),
        }
    }
}

impl Drop for BrowserSession {
    fn drop(&mut self) {
        let inner = self.inner.get_mut();
        if let Some(pump) = inner.pump.take() {
            pump.abort();
        }
        let Some(connection) = inner.connection.take() else {
            return;
        };
        let targets: Vec<String> = self
            .shared
            .lock()
            .tabs
            .iter()
            .map(|tab| tab.target_id.clone())
            .collect();
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        runtime.spawn(async move {
            let quick = Duration::from_secs(3);
            for target in &targets {
                let _ = connection
                    .send_with_timeout(
                        None,
                        "Target.closeTarget",
                        json!({ "targetId": target }),
                        quick,
                    )
                    .await;
            }
            // A browser left with no pages holds nothing of the user's: quit it
            if let Ok(list) = connection
                .send_with_timeout(None, "Target.getTargets", json!({}), quick)
                .await
            {
                let pages = at(&list, "/targetInfos")
                    .as_array()
                    .map(|infos| {
                        infos
                            .iter()
                            .filter(|info| at(info, "/type") == "page")
                            .count()
                    })
                    .unwrap_or(1);
                if pages == 0 {
                    let _ = connection
                        .send_with_timeout(None, "Browser.close", json!({}), quick)
                        .await;
                }
            }
        });
    }
}

impl BrowserSession {
    #[cfg(test)]
    pub(super) fn new_for_tests(params: BrowserParams, cwd: PathBuf) -> Self {
        Self::new(params, cwd)
    }

    /// Quit the browser; for tests that start their own.
    #[cfg(test)]
    pub(super) async fn quit(&self) {
        let inner = self.inner.lock().await;
        if let Some(connection) = &inner.connection {
            let _ = connection.send(None, "Browser.close", json!({})).await;
        }
    }

    fn new(params: BrowserParams, cwd: PathBuf) -> Self {
        Self {
            params,
            cwd,
            halt: BatchHalt::default(),
            inner: tokio::sync::Mutex::new(Inner::default()),
            shared: Arc::default(),
        }
    }

    /// Run one call. `batch` identifies the model response it came from.
    pub async fn run(&self, batch: Option<u64>, input: BrowserInput) -> DeviceActionResult {
        let name = input.action.name();
        if self.halt.is_halted(batch) {
            return DeviceActionResult::error(name, BROWSER_HALT_TEXT);
        }
        if let Some(refusal) = self.refusal(input.action) {
            self.halt.record(batch, true);
            return DeviceActionResult::error(name, refusal);
        }
        let mut inner = self.inner.lock().await;
        let outcome = match self.ensure_connected(&mut inner).await {
            Ok(connection) => self
                .dispatch(&mut inner, &connection, &input)
                .await
                .map(|done| (connection, done)),
            Err(error) => Err(error),
        };
        let result = match outcome {
            Ok((connection, done)) => self.finish(&mut inner, &connection, &input, done).await,
            Err(error) => DeviceActionResult::error(name, error_text(&error)),
        };
        self.halt.record(batch, result.is_error);
        result
    }

    /// The refusal for a member this application turned off.
    fn refusal(&self, action: BrowserAction) -> Option<String> {
        let off = match action {
            BrowserAction::JavascriptExec => !self.params.javascript,
            BrowserAction::FileUpload => !self.params.file_upload,
            _ => false,
        };
        off.then(|| {
            format!(
                "The '{}' action is not permitted by this application's permissions and cannot be used in this session.",
                action.name()
            )
        })
    }

    async fn ensure_connected(&self, inner: &mut Inner) -> Result<Arc<CdpConnection>, String> {
        if let Some(connection) = &inner.connection
            && !connection.is_closed()
        {
            return Ok(Arc::clone(connection));
        }
        // Never connected, or the browser quit: its tabs went with it
        if let Some(pump) = inner.pump.take() {
            pump.abort();
        }
        inner.connection = None;
        inner.window_opened = false;
        inner.reported = None;
        {
            let mut shared = self.shared.lock();
            shared.tabs.clear();
            shared.active = None;
            shared.popups.clear();
        }
        let profile = launch::profile_dir(self.params.profile_dir.as_deref())?;
        let connected = launch::connect_or_launch(
            &profile,
            self.params.executable.as_deref(),
            self.params.headless,
        )
        .await?;
        let connection = connected.connection;
        inner.pump = Some(tokio::spawn(pump(
            Arc::downgrade(&connection),
            connection.subscribe(),
            Arc::clone(&self.shared),
        )));
        connection
            .send(
                None,
                "Target.setDiscoverTargets",
                json!({ "discover": true }),
            )
            .await
            .map_err(|e| e.to_string())?;
        let downloads = launch::default_download_dir();
        launch::create_private_dir(&downloads)?;
        self.shared.lock().download_dir = downloads.clone();
        let _ = connection
            .send(
                None,
                "Browser.setDownloadBehavior",
                json!({ "behavior": "allowAndName", "downloadPath": downloads, "eventsEnabled": true }),
            )
            .await;
        inner.connection = Some(Arc::clone(&connection));
        if connected.launched {
            // The window the browser opened with becomes this session's first tab
            if let Ok(list) = connection.send(None, "Target.getTargets", json!({})).await
                && let Some(target) = at(&list, "/targetInfos").as_array().and_then(|infos| {
                    infos.iter().find(|info| {
                        at(info, "/type") == "page"
                            && at(info, "/url").as_str() == Some("about:blank")
                    })
                })
                && let Some(target_id) = at(target, "/targetId").as_str()
                && let Ok(tab) = self.attach(&connection, target_id).await
            {
                inner.window_opened = true;
                self.shared.lock().active = Some(tab.id);
            }
        }
        Ok(connection)
    }

    async fn attach(&self, connection: &CdpConnection, target_id: &str) -> Result<TabRef, String> {
        let attached = connection
            .send(
                None,
                "Target.attachToTarget",
                json!({ "targetId": target_id, "flatten": true }),
            )
            .await
            .map_err(|e| e.to_string())?;
        let session_id = at(&attached, "/sessionId")
            .as_str()
            .ok_or("the browser did not attach to the tab")?
            .to_owned();
        let tab = {
            let mut shared = self.shared.lock();
            shared.next_tab += 1;
            let tab = Tab::new(format!("tab-{}", shared.next_tab), target_id, session_id);
            let reference = tab.to_ref();
            shared.tabs.push(tab);
            reference
        };
        for method in [
            "Page.enable",
            "Runtime.enable",
            "Network.enable",
            "Log.enable",
        ] {
            let _ = connection
                .send(Some(&tab.session_id), method, json!({}))
                .await;
        }
        if let Ok(info) = connection
            .send(
                None,
                "Target.getTargetInfo",
                json!({ "targetId": target_id }),
            )
            .await
            && let Some(found) = self.shared.lock().tab_mut(&tab.id)
        {
            found.title = at(&info, "/targetInfo/title")
                .as_str()
                .unwrap_or("")
                .to_owned();
            found.url = at(&info, "/targetInfo/url")
                .as_str()
                .unwrap_or("about:blank")
                .to_owned();
        }
        Ok(tab)
    }

    async fn open_tab(
        &self,
        inner: &mut Inner,
        connection: &CdpConnection,
        url: &str,
    ) -> Result<TabRef, String> {
        let new_window = !inner.window_opened;
        let created = connection
            .send(
                None,
                "Target.createTarget",
                json!({ "url": url, "newWindow": new_window }),
            )
            .await
            .map_err(|e| e.to_string())?;
        let target_id = at(&created, "/targetId")
            .as_str()
            .ok_or("the browser did not open a tab")?
            .to_owned();
        if new_window {
            inner.window_opened = true;
            if let Ok(window) = connection
                .send(
                    None,
                    "Browser.getWindowForTarget",
                    json!({ "targetId": target_id }),
                )
                .await
                && let Some(window_id) = at(&window, "/windowId").as_i64()
            {
                let _ = connection
                    .send(
                        None,
                        "Browser.setWindowBounds",
                        json!({ "windowId": window_id, "bounds": {
                            "width": launch::WINDOW_WIDTH, "height": launch::WINDOW_HEIGHT
                        } }),
                    )
                    .await;
            }
        }
        let tab = self.attach(connection, &target_id).await?;
        self.shared.lock().active = Some(tab.id.clone());
        Ok(tab)
    }

    /// The tab a call acts on: the one it names, or the current one, opened if there is none.
    async fn tab(
        &self,
        inner: &mut Inner,
        connection: &CdpConnection,
        requested: Option<&str>,
    ) -> Result<TabRef, String> {
        if let Some(id) = requested.map(str::trim).filter(|id| !id.is_empty()) {
            return self
                .shared
                .lock()
                .tab_ref(id)
                .ok_or_else(|| TAB_MISSING.to_owned());
        }
        if let Some(active) = self.shared.lock().active_ref() {
            return Ok(active);
        }
        let tab = self.open_tab(inner, connection, "about:blank").await?;
        self.shared
            .lock()
            .changes
            .push(Change::TabOpened(tab.id.clone()));
        Ok(tab)
    }

    async fn dispatch(
        &self,
        inner: &mut Inner,
        connection: &Arc<CdpConnection>,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        use BrowserAction as A;
        match input.action {
            A::NewTab => {
                let tab = self.open_tab(inner, connection, "about:blank").await?;
                return Ok(Done::tabs(format!(
                    "Created new tab with tab_id: {}, URL: about:blank. It is now the current tab.",
                    tab.id
                )));
            }
            A::ListTabs => {
                let shared = self.shared.lock();
                return Ok(Done::tabs(if shared.tabs.is_empty() {
                    "No tabs available".to_owned()
                } else {
                    format!("Available tabs:\n{}", shared.inventory(true))
                }));
            }
            A::SwitchTab => {
                let id = required_tab_id(input)?;
                let tab = self.shared.lock().tab_ref(&id).ok_or(TAB_MISSING)?;
                let _ = connection
                    .send(
                        None,
                        "Target.activateTarget",
                        json!({ "targetId": tab.target_id }),
                    )
                    .await;
                self.shared.lock().active = Some(tab.id.clone());
                return Ok(Done::tabs(format!("Switched to tab {}", tab.id)));
            }
            A::CloseTab => {
                let id = required_tab_id(input)?;
                let tab = self.shared.lock().tab_ref(&id).ok_or(TAB_MISSING)?;
                connection
                    .send(
                        None,
                        "Target.closeTarget",
                        json!({ "targetId": tab.target_id }),
                    )
                    .await
                    .map_err(|e| e.to_string())?;
                self.shared.lock().remove_tab(|t| t.id == tab.id);
                return Ok(Done::tabs(format!("Closed tab {}", tab.id)));
            }
            _ => {}
        }
        let tab = self.tab(inner, connection, input.tab_id.as_deref()).await?;
        let c = connection.as_ref();
        match input.action {
            A::Navigate => self.navigate(c, &tab, input).await,
            A::Screenshot => self.screenshot(c, &tab).await,
            A::Zoom => self.zoom(c, &tab, input).await,
            A::LeftClick | A::RightClick | A::MiddleClick | A::DoubleClick | A::TripleClick => {
                self.click(c, &tab, input).await
            }
            A::Hover | A::MouseMove => {
                let (x, y) = self.point(c, &tab, input).await?;
                let buttons = u32::from(self.mouse_down(&tab));
                mouse(c, &tab, "mouseMoved", x, y, "none", buttons, 0, 0).await?;
                Ok(Done::on(confirmation(input), &tab))
            }
            A::LeftClickDrag => self.drag(c, &tab, input).await,
            A::LeftMouseDown | A::LeftMouseUp => {
                let (x, y) = self.point(c, &tab, input).await?;
                let down = input.action == A::LeftMouseDown;
                let kind = if down {
                    "mousePressed"
                } else {
                    "mouseReleased"
                };
                mouse(
                    c,
                    &tab,
                    "mouseMoved",
                    x,
                    y,
                    "none",
                    u32::from(self.mouse_down(&tab)),
                    0,
                    0,
                )
                .await?;
                mouse(c, &tab, kind, x, y, "left", u32::from(down), 1, 0).await?;
                if let Some(found) = self.shared.lock().tab_mut(&tab.id) {
                    found.mouse_down = down;
                }
                Ok(Done::on(confirmation(input), &tab))
            }
            A::Scroll => self.scroll(c, &tab, input).await,
            A::ScrollTo => {
                let reference = required_ref(input)?;
                self.script(c, &tab, "scroll_to", json!({ "ref": reference }))
                    .await?;
                Ok(Done::on(confirmation(input), &tab))
            }
            A::Type => {
                let text = input
                    .text
                    .as_deref()
                    .ok_or("type needs `text`, the text to type")?;
                type_text(c, &tab, text).await?;
                Ok(Done::on(confirmation(input), &tab))
            }
            A::Key => self.key(c, &tab, input).await,
            A::HoldKey => self.hold_key(connection, &tab, input).await,
            A::Wait => {
                let duration = checked_duration("wait", input.duration, MAX_WAIT_SECS)?;
                tokio::time::sleep(Duration::from_secs_f64(duration)).await;
                Ok(Done::on(confirmation(input), &tab))
            }
            A::ReadPage => {
                let filter = input.filter.map(|filter| match filter {
                    ReadPageFilter::Interactive => "interactive",
                    ReadPageFilter::All => "all",
                });
                let read = self
                    .script(
                        c,
                        &tab,
                        "read_page",
                        json!({ "filter": filter, "depth": input.depth, "ref": input.element_ref }),
                    )
                    .await?;
                let mut text = at(&read, "/text").as_str().unwrap_or("").to_owned();
                if text.is_empty() {
                    text = "(empty)".to_owned();
                }
                if at(&read, "/truncated").as_bool() == Some(true) {
                    text.push_str(
                        "\n\n[Output cut at 50000 characters. Read less with a smaller depth or the ref of a container.]",
                    );
                }
                Ok(Done::on(text, &tab))
            }
            A::Find => {
                let query = input
                    .query
                    .as_deref()
                    .ok_or("find needs `query`, a description such as \"search field\"")?;
                let found = self
                    .script(c, &tab, "find", json!({ "query": query }))
                    .await?;
                Ok(Done::on(
                    at(&found, "/text").as_str().unwrap_or("(empty)"),
                    &tab,
                ))
            }
            A::GetPageText => {
                let page = self.script(c, &tab, "get_page_text", json!({})).await?;
                let text = capped_result_text(
                    at(&page, "/text").as_str().unwrap_or("").to_owned(),
                    "Use read_page or find to reach the rest.",
                );
                Ok(Done::on(text, &tab))
            }
            A::FormInput => {
                let reference = required_ref(input)?;
                let value = input.value.clone().ok_or("form_input needs `value`")?;
                self.script(
                    c,
                    &tab,
                    "form_input",
                    json!({ "ref": reference, "value": value }),
                )
                .await?;
                Ok(Done::on(confirmation(input), &tab))
            }
            A::FileUpload => self.file_upload(c, &tab, input).await,
            A::ReadConsole | A::ReadNetwork => {
                let lines: Vec<String> = {
                    let mut shared = self.shared.lock();
                    let found = shared.tab_mut(&tab.id).ok_or(TAB_MISSING)?;
                    let buffer = if input.action == A::ReadConsole {
                        &mut found.console
                    } else {
                        &mut found.network
                    };
                    buffer.drain(..).collect()
                };
                let text = capped_result_text(
                    lines.join("\n"),
                    "Read again soon after the activity you want to see.",
                );
                Ok(Done::on(text, &tab))
            }
            A::JavascriptExec => self.javascript(c, &tab, input).await,
            A::NewTab | A::ListTabs | A::SwitchTab | A::CloseTab => {
                unreachable!("tab management returns above")
            }
        }
    }

    async fn finish(
        &self,
        inner: &mut Inner,
        connection: &CdpConnection,
        input: &BrowserInput,
        done: Done,
    ) -> DeviceActionResult {
        self.adopt_popups(connection).await;
        let mut shared = self.shared.lock();
        let mut lines: Vec<String> = shared.changes.drain(..).map(render_change).collect();
        lines.extend(dialog_lines(&shared.dialogs));
        shared.dialogs.clear();
        let inventory = shared.inventory(false);
        let mut footer = None;
        if input.action == BrowserAction::ListTabs {
            inner.reported = Some(inventory);
        } else if !done.renders_tabs
            && input.action != BrowserAction::Zoom
            && let Some(executed_on) = done.executed_on.as_deref()
            && !shared.tabs.is_empty()
            && (inner.reported.as_deref() != Some(inventory.as_str()) || !lines.is_empty())
        {
            footer = Some(format!(
                "Tab Context:\n- Executed on tab_id: {executed_on}\n- Available tabs:\n{inventory}"
            ));
            inner.reported = Some(inventory);
        }
        let tab = done
            .executed_on
            .as_deref()
            .or(shared.active.as_deref())
            .and_then(|id| shared.tab(id))
            .map(Tab::summary);
        drop(shared);
        let mut text = done.text;
        if !lines.is_empty() {
            text.push_str("\n\n");
            text.push_str(&lines.join("\n"));
        }
        if let Some(footer) = footer {
            text.push_str("\n\n");
            text.push_str(&footer);
        }
        let mut result = DeviceActionResult::ok(input.action.name(), text);
        result.tab = tab;
        match done.image {
            Some(image) => result.with_image(image),
            None => result,
        }
    }

    /// Attach the tabs our pages opened since the last call; the newest becomes current, as the
    /// browser shows it.
    async fn adopt_popups(&self, connection: &CdpConnection) {
        let popups = std::mem::take(&mut self.shared.lock().popups);
        for target_id in popups {
            if self
                .shared
                .lock()
                .tabs
                .iter()
                .any(|tab| tab.target_id == target_id)
            {
                continue;
            }
            if let Ok(tab) = self.attach(connection, &target_id).await {
                let mut shared = self.shared.lock();
                shared.active = Some(tab.id.clone());
                shared.changes.push(Change::TabOpened(tab.id));
            }
        }
    }

    async fn navigate(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let raw = input
            .url
            .as_deref()
            .map(str::trim)
            .filter(|url| !url.is_empty())
            .ok_or(
                "navigate needs `url`: an http(s) URL, or \"back\", \"forward\" or \"reload\"",
            )?;
        let mut events = c.subscribe();
        let sid = Some(tab.session_id.as_str());
        let wait = match raw {
            "back" | "forward" => {
                let history = c
                    .send(sid, "Page.getNavigationHistory", json!({}))
                    .await
                    .map_err(|e| e.to_string())?;
                let current = at(&history, "/currentIndex").as_i64().unwrap_or(0);
                let index = if raw == "back" {
                    current - 1
                } else {
                    current + 1
                };
                let entry = usize::try_from(index)
                    .ok()
                    .and_then(|index| at(&history, "/entries").get(index))
                    .ok_or_else(|| format!("There is no page to go {raw} to."))?;
                c.send(
                    sid,
                    "Page.navigateToHistoryEntry",
                    json!({ "entryId": at(entry, "/id") }),
                )
                .await
                .map_err(|e| e.to_string())?;
                wait_for_load(&mut events, tab, None, LOAD_TIMEOUT).await
            }
            "reload" => {
                c.send(sid, "Page.reload", json!({}))
                    .await
                    .map_err(|e| e.to_string())?;
                wait_for_load(&mut events, tab, None, LOAD_TIMEOUT).await
            }
            _ => {
                let url = self.check_url(raw)?;
                let navigated = c
                    .send(sid, "Page.navigate", json!({ "url": url }))
                    .await
                    .map_err(|e| e.to_string())?;
                if let Some(error) = at(&navigated, "/errorText")
                    .as_str()
                    .filter(|error| !error.is_empty())
                {
                    return Err(format!("Navigation to {url} failed: {error}."));
                }
                match at(&navigated, "/loaderId").as_str() {
                    Some(loader) => {
                        wait_for_load(&mut events, tab, Some(loader), LOAD_TIMEOUT).await
                    }
                    None => Loaded {
                        loaded: true,
                        status: None,
                    },
                }
            }
        };
        let (url, title) = location(c, tab).await;
        let mut line = format!("Navigated to {}", truncate_chars(&one_line(&url), 4096));
        if !title.is_empty() {
            line.push_str(&format!(" — {}", one_line(&title)));
        }
        if let Some(status) = wait.status {
            line.push_str(&format!(" (HTTP {status})"));
        }
        if !wait.loaded {
            line.push_str(". The page is still loading.");
        }
        Ok(Done::on(line, tab))
    }

    /// The URL policy: http(s) only, and the configured hosts.
    fn check_url(&self, raw: &str) -> Result<String, String> {
        if raw.eq_ignore_ascii_case("about:blank") {
            return Ok("about:blank".to_owned());
        }
        let candidate = with_scheme(raw).replace('\\', "/");
        let parsed = url::Url::parse(&candidate)
            .map_err(|_| format!("Navigation refused: {raw} is not a valid URL."))?;
        if !matches!(parsed.scheme(), "http" | "https") {
            return Err("Navigation refused. Only http and https URLs are allowed.".to_owned());
        }
        let host = parsed.host_str().unwrap_or("").to_ascii_lowercase();
        if host.is_empty() {
            return Err(format!("Navigation refused: {raw} names no host."));
        }
        if self
            .params
            .blocked_domains
            .iter()
            .any(|domain| host_matches(&host, domain))
        {
            return Err(format!(
                "Navigation refused: {host} is blocked by [toolset.browser] blocked_domains."
            ));
        }
        if let Some(allowed) = &self.params.allowed_domains
            && !allowed.iter().any(|domain| host_matches(&host, domain))
        {
            return Err(format!(
                "Navigation refused: {host} is not in [toolset.browser] allowed_domains."
            ));
        }
        Ok(parsed.to_string())
    }

    /// The viewport's size in CSS pixels and the device pixel ratio.
    async fn viewport(&self, c: &CdpConnection, tab: &TabRef) -> Result<(f64, f64, f64), String> {
        let answer = c
            .send(
                Some(&tab.session_id),
                "Runtime.evaluate",
                json!({ "expression": "[innerWidth, innerHeight, devicePixelRatio]", "returnByValue": true }),
            )
            .await
            .map_err(|e| e.to_string())?;
        let value = at(&answer, "/result/value");
        let number =
            |i: usize, fallback: f64| value[i].as_f64().filter(|v| *v > 0.0).unwrap_or(fallback);
        Ok((
            number(0, f64::from(launch::WINDOW_WIDTH)),
            number(1, f64::from(launch::WINDOW_HEIGHT)),
            number(2, 1.0),
        ))
    }

    /// The scale of the tab's screenshots: the last screenshot's, or the current viewport's.
    async fn scale(&self, c: &CdpConnection, tab: &TabRef) -> Result<Scale, String> {
        if let Some(scale) = self.shared.lock().tab(&tab.id).and_then(|t| t.scale) {
            return Ok(scale);
        }
        let (width, height, _) = self.viewport(c, tab).await?;
        let scale = Scale::for_source(width, height);
        if let Some(found) = self.shared.lock().tab_mut(&tab.id) {
            found.scale = Some(scale);
        }
        Ok(scale)
    }

    /// The viewport as an image at device resolution, with its size in CSS pixels.
    async fn capture(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
    ) -> Result<(image::DynamicImage, f64, f64), String> {
        let (width, height, _) = self.viewport(c, tab).await?;
        let shot = c
            .send(
                Some(&tab.session_id),
                "Page.captureScreenshot",
                json!({ "format": "png", "fromSurface": true, "captureBeyondViewport": false }),
            )
            .await
            .map_err(|e| e.to_string())?;
        let data = at(&shot, "/data")
            .as_str()
            .ok_or("the browser sent no screenshot")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .map_err(|e| format!("the screenshot could not be read: {e}"))?;
        let image = tokio::task::spawn_blocking(move || screenshot::decode(&bytes))
            .await
            .map_err(|e| e.to_string())??;
        Ok((image, width, height))
    }

    async fn screenshot(&self, c: &CdpConnection, tab: &TabRef) -> Result<Done, String> {
        let (image, width, height) = self.capture(c, tab).await?;
        let scale = Scale::for_source(width, height);
        let fitted = tokio::task::spawn_blocking(move || {
            screenshot::encode_resized(&image, scale.image_width, scale.image_height)
        })
        .await
        .map_err(|e| e.to_string())??;
        if let Some(found) = self.shared.lock().tab_mut(&tab.id) {
            found.scale = Some(scale);
        }
        let text = format!(
            "Captured the viewport of {} as a {}x{} image.",
            tab.id, fitted.width, fitted.height
        );
        Ok(Done::on(text, tab).with_image(fitted))
    }

    async fn zoom(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let region = input
            .region
            .ok_or("zoom needs `region` [x0, y0, x1, y1] in screenshot pixels")?;
        let scale = self.scale(c, tab).await?;
        let (x0, y0, x1, y1) = scale.region_to_source(region)?;
        let (image, width, _) = self.capture(c, tab).await?;
        let device = f64::from(image.width()) / width;
        let crop = (
            (x0 * device).floor() as u32,
            (y0 * device).floor() as u32,
            ((x1 - x0) * device).ceil() as u32,
            ((y1 - y0) * device).ceil() as u32,
        );
        let fitted = tokio::task::spawn_blocking(move || {
            screenshot::zoom(&image, crop, scale.image_width, scale.image_height)
        })
        .await
        .map_err(|e| e.to_string())??;
        let [a, b, c2, d] = region.map(|v| v.round() as i64);
        let text = format!("Zoomed into [{a}, {b}, {c2}, {d}] of {}.", tab.id);
        Ok(Done::on(text, tab).with_image(fitted))
    }

    /// Where a call points: an element's center, scrolled into view, or a screenshot point.
    async fn point(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<(f64, f64), String> {
        if let Some(reference) = input.element_ref.as_deref() {
            let center = self
                .script(c, tab, "center", json!({ "ref": reference }))
                .await?;
            return match (at(&center, "/x").as_f64(), at(&center, "/y").as_f64()) {
                (Some(x), Some(y)) => Ok((x, y)),
                _ => Err(format!("{reference} has no position on the page")),
            };
        }
        if let Some([x, y]) = input.coordinate {
            return self.scale(c, tab).await?.to_source(x, y);
        }
        Err(format!(
            "{} needs `ref` (from read_page or find) or `coordinate` [x, y]",
            input.action.name()
        ))
    }

    fn mouse_down(&self, tab: &TabRef) -> bool {
        self.shared
            .lock()
            .tab(&tab.id)
            .is_some_and(|t| t.mouse_down)
    }

    async fn click(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let modifiers = cdp_modifier_bits(Modifiers::parse(input.modifiers.as_deref())?);
        let (x, y) = self.point(c, tab, input).await?;
        let (button, bit, count) = match input.action {
            BrowserAction::RightClick => ("right", 2, 1),
            BrowserAction::MiddleClick => ("middle", 4, 1),
            BrowserAction::DoubleClick => ("left", 1, 2),
            BrowserAction::TripleClick => ("left", 1, 3),
            _ => ("left", 1, 1),
        };
        let mut events = c.subscribe();
        mouse(c, tab, "mouseMoved", x, y, "none", 0, 0, modifiers).await?;
        for clicks in 1..=count {
            mouse(c, tab, "mousePressed", x, y, button, bit, clicks, modifiers).await?;
            mouse(c, tab, "mouseReleased", x, y, button, 0, clicks, modifiers).await?;
        }
        let opened = settle(&mut events, tab).await;
        self.note_popups(opened);
        Ok(Done::on(confirmation(input), tab))
    }

    /// Tabs a page opened that the event pump has not recorded yet.
    fn note_popups(&self, opened: Vec<String>) {
        let mut shared = self.shared.lock();
        for target in opened {
            let known = shared.popups.contains(&target)
                || shared.tabs.iter().any(|tab| tab.target_id == target);
            if !known {
                shared.popups.push(target);
            }
        }
    }

    async fn drag(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let [sx, sy] = input
            .start_coordinate
            .ok_or("left_click_drag needs `start_coordinate` [x, y] and `coordinate` [x, y]")?;
        let (fx, fy) = self.scale(c, tab).await?.to_source(sx, sy)?;
        let (tx, ty) = self.point(c, tab, input).await?;
        mouse(c, tab, "mouseMoved", fx, fy, "none", 0, 0, 0).await?;
        mouse(c, tab, "mousePressed", fx, fy, "left", 1, 1, 0).await?;
        const STEPS: u32 = 12;
        for step in 1..=STEPS {
            let t = f64::from(step) / f64::from(STEPS);
            mouse(
                c,
                tab,
                "mouseMoved",
                fx + (tx - fx) * t,
                fy + (ty - fy) * t,
                "left",
                1,
                0,
                0,
            )
            .await?;
            tokio::time::sleep(Duration::from_millis(16)).await;
        }
        mouse(c, tab, "mouseReleased", tx, ty, "left", 0, 1, 0).await?;
        Ok(Done::on(confirmation(input), tab))
    }

    async fn scroll(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let direction = input
            .scroll_direction
            .ok_or("scroll needs `scroll_direction`: up, down, left or right")?;
        let amount = input.scroll_amount.unwrap_or(3);
        if !(1..=10).contains(&amount) {
            return Err(format!(
                "`scroll_amount` must be 1 to 10 notches, not {amount}"
            ));
        }
        let (x, y) = if input.coordinate.is_some() || input.element_ref.is_some() {
            self.point(c, tab, input).await?
        } else {
            let (width, height, _) = self.viewport(c, tab).await?;
            (width / 2.0, height / 2.0)
        };
        let notch = 100.0 * f64::from(amount);
        let (dx, dy) = match direction {
            super::ScrollDirection::Up => (0.0, -notch),
            super::ScrollDirection::Down => (0.0, notch),
            super::ScrollDirection::Left => (-notch, 0.0),
            super::ScrollDirection::Right => (notch, 0.0),
        };
        let modifiers = cdp_modifier_bits(Modifiers::parse(input.modifiers.as_deref())?);
        c.send(
            Some(&tab.session_id),
            "Input.dispatchMouseEvent",
            json!({ "type": "mouseWheel", "x": x, "y": y, "deltaX": dx, "deltaY": dy, "modifiers": modifiers }),
        )
        .await
        .map_err(|e| e.to_string())?;
        tokio::time::sleep(Duration::from_millis(150)).await;
        Ok(Done::on(confirmation(input), tab))
    }

    async fn key(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let text = input
            .text
            .as_deref()
            .ok_or("key needs `text`: a key or chord such as \"Enter\" or \"ctrl+a\"")?;
        let chords = keys::parse_sequence(text)?;
        let repeat = input.repeat.unwrap_or(1);
        if !(1..=100).contains(&repeat) {
            return Err(format!("`repeat` must be 1 to 100, not {repeat}"));
        }
        let mut events = c.subscribe();
        for _ in 0..repeat {
            for chord in &chords {
                press_chord(c, tab, chord).await?;
            }
        }
        let opened = settle(&mut events, tab).await;
        self.note_popups(opened);
        Ok(Done::on(confirmation(input), tab))
    }

    async fn hold_key(
        &self,
        connection: &Arc<CdpConnection>,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let text = input
            .text
            .as_deref()
            .ok_or("hold_key needs `text`, a key or chord")?;
        let chord = keys::parse_chord(text.trim())?;
        let duration = checked_duration("hold_key", input.duration, MAX_WAIT_SECS)?;
        chord_down(connection, tab, &chord).await?;
        // Released even when the call is cancelled mid-hold
        let mut release = ReleaseOnDrop {
            connection: Some(Arc::clone(connection)),
            tab: tab.clone(),
            chord: chord.clone(),
        };
        tokio::time::sleep(Duration::from_secs_f64(duration)).await;
        release.connection = None;
        chord_up(connection, tab, &chord).await?;
        Ok(Done::on(confirmation(input), tab))
    }

    async fn file_upload(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let reference = required_ref(input)?;
        let files = self.upload_paths(input.paths.as_deref().unwrap_or_default())?;
        let element = self
            .evaluate_isolated(
                c,
                tab,
                &script_call("element", json!({ "ref": reference, "next": 1 })),
                false,
            )
            .await?;
        let object_id = at(&element, "/objectId").as_str().ok_or_else(|| {
            format!("Error: {reference} is stale or not found on the current page. Re-read the page to get fresh references.")
        })?;
        c.send(
            Some(&tab.session_id),
            "DOM.setFileInputFiles",
            json!({ "files": files, "objectId": object_id }),
        )
        .await
        .map_err(|e| format!("the files could not be attached: {e}"))?;
        Ok(Done::on(confirmation(input), tab))
    }

    /// Upload paths resolved inside the working directory; credentials and large files refused.
    fn upload_paths(&self, paths: &[String]) -> Result<Vec<String>, String> {
        if paths.is_empty() {
            return Err("file_upload needs `paths`, files inside the working directory".to_owned());
        }
        let root = dunce::canonicalize(&self.cwd)
            .map_err(|e| format!("the working directory could not be read: {e}"))?;
        let mut total = 0u64;
        let mut resolved = Vec::new();
        for path in paths {
            let candidate = if Path::new(path).is_absolute() {
                PathBuf::from(path)
            } else {
                self.cwd.join(path)
            };
            let real =
                dunce::canonicalize(&candidate).map_err(|_| format!("{path} does not exist"))?;
            if !real.starts_with(&root) {
                return Err("file_upload path is outside the configured upload roots".to_owned());
            }
            if is_credential_path(&real) {
                return Err(format!(
                    "{path} is where credentials are kept, so it is not uploaded"
                ));
            }
            let meta = std::fs::metadata(&real).map_err(|e| format!("{path}: {e}"))?;
            if !meta.is_file() {
                return Err(format!("{path} is not a file"));
            }
            total += meta.len();
            resolved.push(real.to_string_lossy().into_owned());
        }
        if total > MAX_UPLOAD_BYTES {
            return Err("an upload can include at most 10 MB of files in total".to_owned());
        }
        Ok(resolved)
    }

    async fn javascript(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        input: &BrowserInput,
    ) -> Result<Done, String> {
        let expression = input
            .text
            .as_deref()
            .filter(|text| !text.trim().is_empty())
            .ok_or("javascript_exec needs `text`, the expression to run")?;
        let answer = c
            .send_with_timeout(
                Some(&tab.session_id),
                "Runtime.evaluate",
                json!({
                    "expression": expression, "returnByValue": true, "awaitPromise": true,
                    "userGesture": true, "replMode": true, "timeout": 10_000
                }),
                Duration::from_secs(15),
            )
            .await
            .map_err(|e| e.to_string())?;
        if let Some(details) = answer.get("exceptionDetails") {
            return Err(format!("the script threw: {}", exception_text(details)));
        }
        let text = capped_result_text(remote_value_text(at(&answer, "/result")), "Return less.");
        Ok(Done::on(text, tab))
    }

    /// Run the page script's `op` in the isolated world; `next` keeps refs unique within the tab.
    async fn script(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        op: &str,
        mut opts: Value,
    ) -> Result<Value, String> {
        let next = self.shared.lock().tab(&tab.id).map_or(1, |t| t.next_ref);
        if let Some(object) = opts.as_object_mut() {
            object.insert("next".to_owned(), json!(next));
        }
        let value = self
            .evaluate_isolated(c, tab, &script_call(op, opts), true)
            .await?;
        if let Some(next) = at(&value, "/next").as_u64()
            && let Some(found) = self.shared.lock().tab_mut(&tab.id)
        {
            found.next_ref = found.next_ref.max(next);
        }
        if let Some(error) = at(&value, "/error").as_str() {
            return Err(error.to_owned());
        }
        Ok(value)
    }

    async fn evaluate_isolated(
        &self,
        c: &CdpConnection,
        tab: &TabRef,
        expression: &str,
        by_value: bool,
    ) -> Result<Value, String> {
        for attempt in 0..2 {
            let context = self.world(c, tab, attempt > 0).await?;
            let answer = c
                .send(
                    Some(&tab.session_id),
                    "Runtime.evaluate",
                    json!({
                        "expression": expression, "contextId": context,
                        "returnByValue": by_value, "awaitPromise": true
                    }),
                )
                .await;
            match answer {
                Err(CdpError::Protocol(message)) if attempt == 0 && message.contains("context") => {
                    continue;
                }
                Err(error) => return Err(error.to_string()),
                Ok(answer) => {
                    if let Some(details) = answer.get("exceptionDetails") {
                        return Err(format!(
                            "the page could not be read: {}",
                            exception_text(details)
                        ));
                    }
                    return Ok(if by_value {
                        at(&answer, "/result/value").clone()
                    } else {
                        at(&answer, "/result").clone()
                    });
                }
            }
        }
        Err("the page changed while it was being read; try again".to_owned())
    }

    /// The tab's isolated world: created on first use and again after the page navigates.
    async fn world(&self, c: &CdpConnection, tab: &TabRef, fresh: bool) -> Result<i64, String> {
        if !fresh && let Some(id) = self.shared.lock().tab(&tab.id).and_then(|t| t.world) {
            return Ok(id);
        }
        let created = c
            .send(
                Some(&tab.session_id),
                "Page.createIsolatedWorld",
                json!({ "frameId": tab.target_id, "worldName": "crok" }),
            )
            .await
            .map_err(|e| e.to_string())?;
        let id = at(&created, "/executionContextId")
            .as_i64()
            .ok_or("the browser did not open a context for the page script")?;
        if let Some(found) = self.shared.lock().tab_mut(&tab.id) {
            found.world = Some(id);
        }
        Ok(id)
    }
}

/// Releases a held chord if `hold_key` is cancelled; disarmed by clearing `connection`.
struct ReleaseOnDrop {
    connection: Option<Arc<CdpConnection>>,
    tab: TabRef,
    chord: Chord,
}

impl Drop for ReleaseOnDrop {
    fn drop(&mut self) {
        let (Some(connection), Ok(runtime)) = (
            self.connection.take(),
            tokio::runtime::Handle::try_current(),
        ) else {
            return;
        };
        let tab = self.tab.clone();
        let chord = self.chord.clone();
        runtime.spawn(async move {
            let _ = chord_up(&connection, &tab, &chord).await;
        });
    }
}

fn script_call(op: &str, opts: Value) -> String {
    format!("({})({}, {})", PAGE_SCRIPT.trim_end(), json!(op), opts)
}

fn required_ref(input: &BrowserInput) -> Result<&str, String> {
    input
        .element_ref
        .as_deref()
        .filter(|r| !r.trim().is_empty())
        .ok_or_else(|| {
            format!(
                "{} needs `ref`, from read_page or find",
                input.action.name()
            )
        })
}

fn required_tab_id(input: &BrowserInput) -> Result<String, String> {
    input
        .tab_id
        .as_deref()
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| format!("{} needs `tab_id`", input.action.name()))
}

/// The acknowledgment for a pure action, filled from its input.
fn confirmation(input: &BrowserInput) -> String {
    let Some(template) = input.action.confirmation() else {
        return "Done.".to_owned();
    };
    fill_confirmation(
        template,
        ConfirmationFields {
            scroll_direction: input.scroll_direction.map(super::ScrollDirection::as_str),
            text: input.text.as_deref(),
            duration: input.duration,
            element_ref: input.element_ref.as_deref(),
        },
    )
}

fn error_text(error: &str) -> String {
    let error = error.trim();
    if error.starts_with("Error")
        || error.starts_with("Navigation refused")
        || error.starts_with("The ")
        || error.starts_with("Not executed")
    {
        error.to_owned()
    } else if error == CdpError::Closed.to_string() {
        "Error: the browser closed. The next browser call opens it again.".to_owned()
    } else {
        format!("Error: {error}")
    }
}

/// `url` with `https://` (or `http://` for this machine) when it names no scheme.
pub fn with_scheme(url: &str) -> String {
    let url = url.trim();
    if has_scheme(url) {
        return url.to_owned();
    }
    let authority = url.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit('@').next().unwrap_or("");
    let host = if host.starts_with('[') {
        host.split(']')
            .next()
            .map(|h| h.trim_start_matches('['))
            .unwrap_or("")
    } else {
        host.split(':').next().unwrap_or("")
    };
    if is_local_host(host) {
        format!("http://{url}")
    } else {
        format!("https://{url}")
    }
}

fn has_scheme(url: &str) -> bool {
    let Some((scheme, rest)) = url.split_once(':') else {
        return false;
    };
    let valid = scheme
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-'));
    // `localhost:3000/app` is a host and a port, not a scheme
    let port_follows = rest
        .split(['/', '?', '#'])
        .next()
        .is_some_and(|port| !port.is_empty() && port.chars().all(|c| c.is_ascii_digit()));
    valid && !port_follows
}

fn is_local_host(host: &str) -> bool {
    let host = host.to_ascii_lowercase();
    host == "localhost"
        || host.ends_with(".localhost")
        || host == "::1"
        || host == "0.0.0.0"
        || host.starts_with("127.")
}

fn host_matches(host: &str, domain: &str) -> bool {
    let domain = domain
        .trim()
        .trim_start_matches("*.")
        .trim_start_matches('.')
        .to_ascii_lowercase();
    !domain.is_empty() && (host == domain || host.ends_with(&format!(".{domain}")))
}

fn is_credential_path(path: &Path) -> bool {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    let extension = path
        .extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    name.starts_with(".env")
        || name.starts_with("id_rsa")
        || name.starts_with("id_ed25519")
        || matches!(extension.as_str(), "pem" | "key" | "p12" | "pfx")
        || path.components().any(|part| {
            matches!(
                part.as_os_str().to_string_lossy().as_ref(),
                ".ssh" | ".gnupg" | ".aws"
            )
        })
}

fn escape_title(title: &str) -> String {
    truncate_chars(&one_line(title), 300)
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
}

fn cdp_modifier_bits(m: Modifiers) -> u32 {
    u32::from(m.alt)
        | (u32::from(m.ctrl) << 1)
        | (u32::from(m.meta) << 2)
        | (u32::from(m.shift) << 3)
}

#[allow(clippy::too_many_arguments)]
async fn mouse(
    c: &CdpConnection,
    tab: &TabRef,
    kind: &str,
    x: f64,
    y: f64,
    button: &str,
    buttons: u32,
    clicks: u32,
    modifiers: u32,
) -> Result<(), String> {
    c.send(
        Some(&tab.session_id),
        "Input.dispatchMouseEvent",
        json!({
            "type": kind, "x": x, "y": y, "button": button, "buttons": buttons,
            "clickCount": clicks, "modifiers": modifiers
        }),
    )
    .await
    .map(drop)
    .map_err(|e| e.to_string())
}

async fn key_event(
    c: &CdpConnection,
    tab: &TabRef,
    kind: &str,
    chord: &Chord,
    with_text: bool,
    command: Option<&str>,
) -> Result<(), String> {
    let mut params = json!({
        "type": kind, "key": chord.key.key, "code": chord.key.code,
        "windowsVirtualKeyCode": chord.key.key_code, "nativeVirtualKeyCode": chord.key.key_code,
        "modifiers": chord.cdp_modifiers(), "location": chord.key.location
    });
    if let Some(object) = params.as_object_mut() {
        if with_text && let Some(text) = &chord.key.text {
            object.insert("text".to_owned(), json!(text));
            object.insert("unmodifiedText".to_owned(), json!(text));
        }
        if let Some(command) = command {
            object.insert("commands".to_owned(), json!([command]));
        }
    }
    c.send(Some(&tab.session_id), "Input.dispatchKeyEvent", params)
        .await
        .map(drop)
        .map_err(|e| e.to_string())
}

/// The modifier keys of a chord, each pressed on its own, in the order a person holds them.
fn modifier_chords(chord: &Chord) -> Vec<Chord> {
    let m = chord.modifiers;
    [
        (m.ctrl, "Control"),
        (m.alt, "Alt"),
        (m.meta, "Meta"),
        (m.shift, "Shift"),
    ]
    .into_iter()
    .filter(|(on, _)| *on)
    .filter_map(|(_, name)| keys::key_def(name))
    .map(|key| Chord {
        modifiers: chord.modifiers,
        key,
    })
    .collect()
}

async fn chord_down(c: &CdpConnection, tab: &TabRef, chord: &Chord) -> Result<(), String> {
    for modifier in modifier_chords(chord) {
        key_event(c, tab, "rawKeyDown", &modifier, false, None).await?;
    }
    let inserts = chord.inserts_text();
    let command = if cfg!(target_os = "macos") {
        chord.mac_editing_command()
    } else {
        None
    };
    let kind = if inserts { "keyDown" } else { "rawKeyDown" };
    key_event(c, tab, kind, chord, inserts, command).await
}

async fn chord_up(c: &CdpConnection, tab: &TabRef, chord: &Chord) -> Result<(), String> {
    key_event(c, tab, "keyUp", chord, false, None).await?;
    for modifier in modifier_chords(chord).iter().rev() {
        key_event(c, tab, "keyUp", modifier, false, None).await?;
    }
    Ok(())
}

async fn press_chord(c: &CdpConnection, tab: &TabRef, chord: &Chord) -> Result<(), String> {
    chord_down(c, tab, chord).await?;
    chord_up(c, tab, chord).await
}

/// Type `text` at the focus: keys for what a US keyboard types, inserted text for the rest.
async fn type_text(c: &CdpConnection, tab: &TabRef, text: &str) -> Result<(), String> {
    let mut pending = String::new();
    for ch in text.chars() {
        match keys::char_def(ch) {
            Some(key) => {
                flush_insert(c, tab, &mut pending).await?;
                let chord = Chord {
                    modifiers: Modifiers::default(),
                    key,
                };
                press_chord(c, tab, &chord).await?;
            }
            None => pending.push(ch),
        }
    }
    flush_insert(c, tab, &mut pending).await
}

async fn flush_insert(c: &CdpConnection, tab: &TabRef, pending: &mut String) -> Result<(), String> {
    if pending.is_empty() {
        return Ok(());
    }
    let text = std::mem::take(pending);
    c.send(
        Some(&tab.session_id),
        "Input.insertText",
        json!({ "text": text }),
    )
    .await
    .map(drop)
    .map_err(|e| e.to_string())
}

/// After input that may navigate or open a tab (a click, Enter), wait for what it starts. Returns
/// the tabs the page opened, which the event pump may not have recorded yet.
async fn settle(events: &mut broadcast::Receiver<CdpEvent>, tab: &TabRef) -> Vec<String> {
    let deadline = Instant::now() + SETTLE_WINDOW;
    let mut opened = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return opened;
        }
        let event = match tokio::time::timeout(remaining, events.recv()).await {
            Ok(Ok(event)) => event,
            Ok(Err(RecvError::Lagged(_))) => continue,
            _ => return opened,
        };
        if event.method == "Target.targetCreated" {
            let info = at(&event.params, "/targetInfo");
            if at(info, "/type") == "page"
                && at(info, "/openerId").as_str() == Some(tab.target_id.as_str())
                && let Some(target) = at(info, "/targetId").as_str()
            {
                opened.push(target.to_owned());
            }
            continue;
        }
        let main_frame = at(&event.params, "/frameId").as_str() == Some(tab.target_id.as_str());
        if event.session_id.as_deref() == Some(tab.session_id.as_str())
            && main_frame
            && matches!(
                event.method.as_str(),
                "Page.frameStartedLoading" | "Page.frameRequestedNavigation"
            )
        {
            wait_for_load(events, tab, None, SETTLE_LOAD_TIMEOUT).await;
            return opened;
        }
    }
}

async fn wait_for_load(
    events: &mut broadcast::Receiver<CdpEvent>,
    tab: &TabRef,
    loader: Option<&str>,
    timeout: Duration,
) -> Loaded {
    let deadline = Instant::now() + timeout;
    let mut status = None;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Loaded {
                loaded: false,
                status,
            };
        }
        let event = match tokio::time::timeout(remaining, events.recv()).await {
            Ok(Ok(event)) => event,
            Ok(Err(RecvError::Lagged(_))) => continue,
            _ => {
                return Loaded {
                    loaded: false,
                    status,
                };
            }
        };
        if event.session_id.as_deref() != Some(tab.session_id.as_str()) {
            continue;
        }
        let p = &event.params;
        match event.method.as_str() {
            "Network.responseReceived"
                if at(p, "/type") == "Document"
                    && at(p, "/frameId").as_str() == Some(tab.target_id.as_str())
                    && loader.is_none_or(|loader| at(p, "/loaderId").as_str() == Some(loader)) =>
            {
                status = at(p, "/response/status").as_u64();
            }
            "Page.loadEventFired" => {
                return Loaded {
                    loaded: true,
                    status,
                };
            }
            "Page.navigatedWithinDocument" | "Page.frameStoppedLoading"
                if at(p, "/frameId").as_str() == Some(tab.target_id.as_str())
                    && (loader.is_none() || event.method == "Page.frameStoppedLoading") =>
            {
                return Loaded {
                    loaded: true,
                    status,
                };
            }
            _ => {}
        }
    }
}

/// The tab's URL and title as the browser reports them.
async fn location(c: &CdpConnection, tab: &TabRef) -> (String, String) {
    match c
        .send(
            None,
            "Target.getTargetInfo",
            json!({ "targetId": tab.target_id }),
        )
        .await
    {
        Ok(info) => (
            at(&info, "/targetInfo/url")
                .as_str()
                .unwrap_or("")
                .to_owned(),
            at(&info, "/targetInfo/title")
                .as_str()
                .unwrap_or("")
                .to_owned(),
        ),
        Err(_) => (String::new(), String::new()),
    }
}

fn exception_text(details: &Value) -> String {
    let text = at(details, "/exception/description")
        .as_str()
        .or_else(|| at(details, "/text").as_str())
        .unwrap_or("unknown error");
    truncate_chars(text.lines().next().unwrap_or(text), 1000)
}

fn remote_value_text(result: &Value) -> String {
    if at(result, "/type") == "undefined" {
        return "undefined".to_owned();
    }
    if let Some(value) = result.get("value") {
        return match value {
            Value::String(text) => text.clone(),
            other => serde_json::to_string_pretty(other).unwrap_or_default(),
        };
    }
    at(result, "/unserializableValue")
        .as_str()
        .or_else(|| at(result, "/description").as_str())
        .unwrap_or("")
        .to_owned()
}

fn render_change(change: Change) -> String {
    let quoted = |value: &str| {
        serde_json::to_string(&truncate_chars(&one_line(value), 4096)).unwrap_or_default()
    };
    match change {
        Change::TabOpened(id) => format!("A new tab opened: {id}."),
        Change::DownloadStarted { id, url } => {
            format!(
                "Download started with download_id: {id}, URL: {}.",
                quoted(&url)
            )
        }
        Change::DownloadCompleted {
            id,
            url,
            path,
            size,
        } => {
            let mut line = format!(
                "Download completed with download_id: {id}, URL: {}.",
                quoted(&url)
            );
            if let Some(path) = path {
                line.push_str(&format!(" Saved to {}.", quoted(&path)));
            }
            if let Some(size) = size {
                line.push_str(&format!(" Size: {size} bytes."));
            }
            line
        }
        Change::DownloadFailed { id, url, error } => format!(
            "Download failed with download_id: {id}, URL: {}. Error: {}.",
            quoted(&url),
            quoted(&error)
        ),
    }
}

/// One line per dismissed dialog, a few at most, as the SDK reports them.
fn dialog_lines(dialogs: &[(String, String)]) -> Vec<String> {
    let mut lines: Vec<String> = dialogs
        .iter()
        .take(3)
        .map(|(kind, message)| {
            let kind = truncate_chars(&one_line(kind), 20);
            let kind = if kind.is_empty() {
                "dialog".to_owned()
            } else {
                kind
            };
            let article = if kind.starts_with(['a', 'e', 'i', 'o', 'u']) {
                "An"
            } else {
                "A"
            };
            let noun = if kind == "dialog" {
                kind
            } else {
                format!("{kind} dialog")
            };
            let message = truncate_chars(&one_line(message), 200);
            let quoted = if message.is_empty() {
                String::new()
            } else {
                format!(" {}", serde_json::to_string(&message).unwrap_or_default())
            };
            format!("{article} {noun}{quoted} was dismissed.")
        })
        .collect();
    if dialogs.len() > 3 {
        lines.push(format!(
            "{} more dialogs were dismissed.",
            dialogs.len() - 3
        ));
    }
    lines
}

/// A URL for a log line, with credential-like query values hidden.
fn redacted_url(url: &str) -> String {
    let Ok(mut parsed) = url::Url::parse(url) else {
        return truncate_chars(url, 300);
    };
    if parsed.query().is_some() {
        const SECRET: &[&str] = &[
            "token", "key", "secret", "password", "auth", "sig", "code", "session",
        ];
        let pairs: Vec<(String, String)> = parsed
            .query_pairs()
            .map(|(k, v)| {
                let hide = SECRET.iter().any(|s| k.to_ascii_lowercase().contains(s));
                (
                    k.into_owned(),
                    if hide {
                        "***".to_owned()
                    } else {
                        v.into_owned()
                    },
                )
            })
            .collect();
        parsed.query_pairs_mut().clear().extend_pairs(pairs);
    }
    truncate_chars(parsed.as_str(), 300)
}

fn push_bounded(buffer: &mut VecDeque<String>, line: String) {
    if buffer.len() == BUFFER_LIMIT {
        buffer.pop_front();
    }
    buffer.push_back(truncate_chars(&line, ENTRY_CHARS));
}

/// Collect what the browser reports while no action is waiting for it.
async fn pump(
    connection: Weak<CdpConnection>,
    mut events: broadcast::Receiver<CdpEvent>,
    shared: Arc<parking_lot::Mutex<Shared>>,
) {
    loop {
        let event = match events.recv().await {
            Ok(event) => event,
            Err(RecvError::Lagged(_)) => continue,
            Err(RecvError::Closed) => return,
        };
        if let Some((session_id, method, params)) = record(&shared, &event)
            && let Some(connection) = connection.upgrade()
        {
            tokio::spawn(async move {
                let _ = connection.send(Some(&session_id), method, params).await;
            });
        }
    }
}

/// Fold one event into the session's state; a command to send back when one is due.
fn record(
    shared: &parking_lot::Mutex<Shared>,
    event: &CdpEvent,
) -> Option<(String, &'static str, Value)> {
    let mut s = shared.lock();
    let p = &event.params;
    match event.method.as_str() {
        "Target.targetCreated" => {
            let info = at(p, "/targetInfo");
            let opener = at(info, "/openerId").as_str()?;
            if at(info, "/type") == "page" && s.tabs.iter().any(|tab| tab.target_id == opener) {
                s.popups.push(at(info, "/targetId").as_str()?.to_owned());
            }
        }
        "Target.targetInfoChanged" => {
            let info = at(p, "/targetInfo");
            let target = at(info, "/targetId").as_str()?;
            if let Some(tab) = s.tabs.iter_mut().find(|tab| tab.target_id == target) {
                tab.title = at(info, "/title").as_str().unwrap_or("").to_owned();
                tab.url = at(info, "/url").as_str().unwrap_or("").to_owned();
            }
        }
        "Target.targetDestroyed" => {
            let target = at(p, "/targetId").as_str()?.to_owned();
            s.popups.retain(|popup| *popup != target);
            s.remove_tab(|tab| tab.target_id == target);
        }
        "Target.detachedFromTarget" => {
            let session = at(p, "/sessionId").as_str()?.to_owned();
            s.remove_tab(|tab| tab.session_id == session);
        }
        "Browser.downloadWillBegin" => {
            let frame = at(p, "/frameId").as_str()?;
            if s.tabs.iter().any(|tab| tab.target_id == frame) {
                s.next_download += 1;
                let id = format!("dl-{}", s.next_download);
                let url = redacted_url(at(p, "/url").as_str().unwrap_or(""));
                let guid = at(p, "/guid").as_str()?.to_owned();
                s.changes.push(Change::DownloadStarted {
                    id: id.clone(),
                    url: url.clone(),
                });
                s.downloads.insert(
                    guid,
                    Download {
                        id,
                        url,
                        suggested: at(p, "/suggestedFilename")
                            .as_str()
                            .unwrap_or("download")
                            .to_owned(),
                    },
                );
            }
        }
        "Browser.downloadProgress" => {
            let guid = at(p, "/guid").as_str()?;
            let state = at(p, "/state").as_str()?;
            if state == "inProgress" {
                return None;
            }
            let download = s.downloads.remove(guid)?;
            let change = if state == "completed" {
                let path = name_download(&s.download_dir, guid, &download.suggested);
                Change::DownloadCompleted {
                    id: download.id,
                    url: download.url,
                    path,
                    size: at(p, "/totalBytes").as_u64(),
                }
            } else {
                Change::DownloadFailed {
                    id: download.id,
                    url: download.url,
                    error: "canceled".to_owned(),
                }
            };
            s.changes.push(change);
        }
        "Page.javascriptDialogOpening" => {
            let session_id = event.session_id.as_deref()?;
            s.by_session_mut(session_id)?;
            let kind = at(p, "/type").as_str().unwrap_or("dialog").to_owned();
            // An alert only has OK, and leaving a page is what the action asked for
            let accept = matches!(kind.as_str(), "alert" | "beforeunload");
            s.dialogs
                .push((kind, at(p, "/message").as_str().unwrap_or("").to_owned()));
            return Some((
                session_id.to_owned(),
                "Page.handleJavaScriptDialog",
                json!({ "accept": accept }),
            ));
        }
        _ => {
            let session_id = event.session_id.as_deref()?;
            let tab = s.by_session_mut(session_id)?;
            tab_event(tab, &event.method, p);
        }
    }
    None
}

fn tab_event(tab: &mut Tab, method: &str, p: &Value) -> Option<()> {
    match method {
        "Runtime.consoleAPICalled" => {
            let level = at(p, "/type").as_str().unwrap_or("log");
            let text = at(p, "/args")
                .as_array()
                .map(|args| {
                    args.iter()
                        .map(remote_value_text)
                        .collect::<Vec<_>>()
                        .join(" ")
                })
                .unwrap_or_default();
            let frame = at(p, "/stackTrace/callFrames/0");
            let place = match (
                at(frame, "/url").as_str(),
                at(frame, "/lineNumber").as_u64(),
            ) {
                (Some(url), Some(line)) if !url.is_empty() => {
                    format!(" ({}:{})", redacted_url(url), line + 1)
                }
                _ => String::new(),
            };
            push_bounded(
                &mut tab.console,
                format!("[{level}] {}{place}", one_line(&text)),
            );
        }
        "Runtime.exceptionThrown" => {
            let details = at(p, "/exceptionDetails");
            push_bounded(
                &mut tab.console,
                format!("[exception] {}", exception_text(details)),
            );
        }
        "Log.entryAdded" => {
            let entry = at(p, "/entry");
            let place = at(entry, "/url")
                .as_str()
                .filter(|u| !u.is_empty())
                .map(|u| format!(" ({})", redacted_url(u)))
                .unwrap_or_default();
            push_bounded(
                &mut tab.console,
                format!(
                    "[{}] {}{place}",
                    at(entry, "/level").as_str().unwrap_or("info"),
                    one_line(at(entry, "/text").as_str().unwrap_or(""))
                ),
            );
        }
        "Network.requestWillBeSent" => {
            let id = at(p, "/requestId").as_str()?.to_owned();
            if tab.requests.len() > BUFFER_LIMIT {
                tab.requests.clear();
            }
            tab.requests.insert(
                id,
                Request {
                    method: at(p, "/request/method")
                        .as_str()
                        .unwrap_or("GET")
                        .to_owned(),
                    url: redacted_url(at(p, "/request/url").as_str().unwrap_or("")),
                    started: at(p, "/timestamp").as_f64().unwrap_or(0.0),
                    status: None,
                    mime: None,
                },
            );
        }
        "Network.responseReceived" => {
            if let Some(request) = tab.requests.get_mut(at(p, "/requestId").as_str()?) {
                request.status = at(p, "/response/status").as_u64();
                request.mime = at(p, "/response/mimeType").as_str().map(str::to_owned);
            }
        }
        "Network.loadingFinished" | "Network.loadingFailed" => {
            let request = tab.requests.remove(at(p, "/requestId").as_str()?)?;
            let ms = ((at(p, "/timestamp").as_f64().unwrap_or(request.started) - request.started)
                * 1000.0)
                .max(0.0)
                .round();
            let outcome = if method == "Network.loadingFailed" {
                format!(
                    "failed ({})",
                    at(p, "/errorText").as_str().unwrap_or("error")
                )
            } else {
                format!(
                    "{} {}",
                    request
                        .status
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| "-".to_owned()),
                    request.mime.unwrap_or_default()
                )
            };
            push_bounded(
                &mut tab.network,
                format!(
                    "{} {} → {} ({ms} ms)",
                    request.method,
                    request.url,
                    outcome.trim()
                ),
            );
        }
        "Page.frameNavigated" if at(p, "/frame/parentId").is_null() => {
            tab.url = at(p, "/frame/url").as_str().unwrap_or("").to_owned();
            tab.world = None;
        }
        "Page.navigatedWithinDocument"
            if at(p, "/frameId").as_str() == Some(tab.target_id.as_str()) =>
        {
            tab.url = at(p, "/url").as_str().unwrap_or("").to_owned();
        }
        "Runtime.executionContextsCleared" => tab.world = None,
        _ => {}
    }
    Some(())
}

/// Give a finished download its suggested name, kept unique in the folder.
fn name_download(dir: &Path, guid: &str, suggested: &str) -> Option<String> {
    let from = dir.join(guid);
    let safe: String = suggested
        .chars()
        .map(|c| {
            if matches!(c, '/' | '\\' | ':') || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    let safe = if safe.trim().is_empty() || safe.starts_with('.') {
        format!("download{safe}")
    } else {
        safe
    };
    let path = Path::new(&safe);
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    let extension = path
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();
    let mut target = dir.join(&safe);
    let mut n = 1;
    while target.exists() {
        target = dir.join(format!("{stem} ({n}){extension}"));
        n += 1;
    }
    match std::fs::rename(&from, &target) {
        Ok(()) => Some(target.to_string_lossy().into_owned()),
        Err(_) => from.exists().then(|| from.to_string_lossy().into_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn urls_get_a_scheme_and_local_hosts_get_http() {
        assert_eq!(with_scheme("example.com/docs"), "https://example.com/docs");
        assert_eq!(
            with_scheme("localhost:3000/app"),
            "http://localhost:3000/app"
        );
        assert_eq!(with_scheme("127.0.0.1:8080"), "http://127.0.0.1:8080");
        assert_eq!(with_scheme("http://example.com"), "http://example.com");
        assert_eq!(with_scheme("javascript:alert(1)"), "javascript:alert(1)");
        assert_eq!(with_scheme("[::1]:5173"), "http://[::1]:5173");
    }

    #[test]
    fn the_url_policy_refuses_schemes_and_hosts() {
        let params = BrowserParams {
            blocked_domains: vec!["evil.test".into()],
            ..Default::default()
        };
        let session = BrowserSession::new(params, PathBuf::from("/tmp"));
        assert_eq!(
            session.check_url("example.com").unwrap(),
            "https://example.com/"
        );
        assert!(
            session
                .check_url("javascript:alert(1)")
                .unwrap_err()
                .contains("Only http and https")
        );
        assert!(session.check_url("file:///etc/passwd").is_err());
        assert!(
            session
                .check_url("https://a.evil.test/x")
                .unwrap_err()
                .contains("blocked")
        );
        assert_eq!(session.check_url("about:blank").unwrap(), "about:blank");
        let only = BrowserParams {
            allowed_domains: Some(vec!["docs.rs".into()]),
            ..Default::default()
        };
        let session = BrowserSession::new(only, PathBuf::from("/tmp"));
        assert!(session.check_url("https://docs.rs/serde").is_ok());
        assert!(
            session
                .check_url("https://crates.io")
                .unwrap_err()
                .contains("allowed_domains")
        );
    }

    #[test]
    fn confirmations_fill_their_fields_once() {
        let mut input = BrowserInput::new(BrowserAction::Scroll);
        input.scroll_direction = Some(super::super::ScrollDirection::Down);
        assert_eq!(confirmation(&input), "Scrolled down.");
        let mut input = BrowserInput::new(BrowserAction::Key);
        input.text = Some("{ref}".into());
        assert_eq!(confirmation(&input), "Pressed {ref}.");
        let mut input = BrowserInput::new(BrowserAction::Wait);
        input.duration = Some(2.0);
        assert_eq!(confirmation(&input), "Waited 2s.");
        let mut input = BrowserInput::new(BrowserAction::FormInput);
        input.element_ref = Some("ref_4".into());
        assert_eq!(confirmation(&input), "Set the value of ref_4.");
    }

    #[test]
    fn dialogs_and_downloads_render_as_the_toolset_reports_them() {
        let dialogs: Vec<(String, String)> = (0..5)
            .map(|i| ("confirm".to_owned(), format!("Sure {i}?")))
            .collect();
        let lines = dialog_lines(&dialogs);
        assert_eq!(lines[0], "A confirm dialog \"Sure 0?\" was dismissed.");
        assert_eq!(lines[3], "2 more dialogs were dismissed.");
        assert_eq!(
            dialog_lines(&[("alert".into(), String::new())])[0],
            "An alert dialog was dismissed."
        );
        let line = render_change(Change::DownloadCompleted {
            id: "dl-1".into(),
            url: "https://e.test/a.csv".into(),
            path: Some("/d/a.csv".into()),
            size: Some(12),
        });
        assert_eq!(
            line,
            "Download completed with download_id: dl-1, URL: \"https://e.test/a.csv\". Saved to \"/d/a.csv\". Size: 12 bytes."
        );
    }

    #[test]
    fn inventory_marks_the_current_tab_only_when_asked() {
        let mut shared = Shared::default();
        let mut tab = Tab::new("tab-1".into(), "t1", "s1".into());
        tab.title = "Docs \"v2\"".into();
        tab.url = "https://example.com/docs".into();
        shared.tabs.push(tab);
        shared.active = Some("tab-1".into());
        assert_eq!(
            shared.inventory(true),
            "  • tab_id tab-1: \"Docs \\\"v2\\\"\" (https://example.com/docs) (current)"
        );
        assert!(!shared.inventory(false).contains("(current)"));
    }

    #[test]
    fn secrets_leave_logged_urls() {
        let url = redacted_url("https://api.test/v1?access_token=abc&page=2");
        assert!(url.contains("access_token=***") && url.contains("page=2"));
    }

    #[test]
    fn credentials_and_outside_paths_are_not_uploaded() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), "hi").unwrap();
        std::fs::write(dir.path().join(".env"), "SECRET=1").unwrap();
        let session = BrowserSession::new(BrowserParams::default(), dir.path().to_path_buf());
        assert_eq!(session.upload_paths(&["a.txt".into()]).unwrap().len(), 1);
        assert!(
            session
                .upload_paths(&[".env".into()])
                .unwrap_err()
                .contains("credentials")
        );
        assert!(
            session
                .upload_paths(&["/etc/hosts".into()])
                .unwrap_err()
                .contains("outside")
        );
        assert!(session.upload_paths(&[]).is_err());
    }
}
