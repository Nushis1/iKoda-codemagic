//! Koda's own renewal tool, Rust side. Stage 2a: sign in to an Apple ID (with two-factor) through
//! isideload. Swift calls these C functions from a background thread; each one blocks until done.
//! Pairing, signing Koda and installing it come in later stages.
//!
//! API as of isideload 0.5.2 (docs.rs/isideload/0.5.2): `AppleAccount::builder(email).login(password,
//! callback)`, where the callback is asked for a two-factor code and answers a `TwoFactorCallbackResponse`.

use std::ffi::{c_char, c_void, CStr};
use std::path::PathBuf;
use std::panic::{self, AssertUnwindSafe};
use std::sync::{Mutex, Once, OnceLock};

use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackParams, TwoFactorCallbackResponse};
use isideload::dev::app_ids::AppIdsApi;
use isideload::dev::certificates::CertificatesApi;
use isideload::dev::developer_session::DeveloperSession;
use isideload::dev::device_type::DeveloperDeviceType;
use isideload::dev::devices::DevicesApi;
use isideload::dev::teams::TeamsApi;
use isideload::sideload::SideloaderBuilder;
use rootcause::option_ext::OptionExt;
use isideload::util::fs_storage::FsStorage;
use rootcause::prelude::Report;
use tokio::runtime::{Builder, Runtime};

/// Returns 1 when the library is linked in. Swift can call it to check.
#[no_mangle]
pub extern "C" fn koda_renewer_ping() -> u32 {
    1
}

fn runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("could not start the tokio runtime")
    })
}

/// What the last panic said and where, kept so it can be shown instead of crashing the app.
static LAST_PANIC: Mutex<Option<String>> = Mutex::new(None);

fn remember_panics() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        panic::set_hook(Box::new(|info| {
            if let Ok(mut slot) = LAST_PANIC.lock() {
                *slot = Some(info.to_string());
            }
        }));
    });
}

fn last_panic() -> String {
    LAST_PANIC
        .lock()
        .ok()
        .and_then(|mut slot| slot.take())
        .unwrap_or_else(|| "no details".to_string())
}

/// TLS needs a crypto provider chosen once for the whole process; reqwest won't pick one itself.
/// Harmless to call again: once one is installed, the call just says so and is ignored.
fn install_crypto() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}

/// Call once at the start: without it, network errors from isideload show no details.
/// Returns false if isideload could not set itself up.
#[no_mangle]
pub extern "C" fn koda_renewer_init() -> bool {
    remember_panics();
    install_crypto();
    panic::catch_unwind(|| isideload::init().is_ok()).unwrap_or(false)
}

/// Asked about two-factor sign-in. `request` is JSON describing what Apple offers:
/// `{"needsMethod": bool, "sms": bool, "selectedNumber": id|null, "numbers": [{"id","label","mode"}]}`.
/// Swift writes its answer into `buffer` (UTF-8, NUL-ended, at most `capacity` bytes) and returns true,
/// or returns false to cancel the sign-in. The answer is one of:
/// `devices` (send the code to the trusted devices), `sms:<id>` (text the number with that id),
/// `resend`, or `code:<digits>`.
pub type CodeCallback =
    extern "C" fn(user: *mut c_void, request: *const c_char, buffer: *mut c_char, capacity: usize) -> bool;

/// The callback and the pointer Swift gave with it. Swift keeps `user` alive for the whole call.
#[derive(Clone, Copy)]
struct Context {
    callback: CodeCallback,
    user: *mut c_void,
}

unsafe impl Send for Context {}
unsafe impl Sync for Context {}

impl Context {
    /// Blocks until Swift answers. Run it off the async workers.
    fn ask(self, request: &str) -> Option<String> {
        let request = std::ffi::CString::new(request).ok()?;
        let mut buffer = vec![0u8; 64];
        if !(self.callback)(self.user, request.as_ptr(), buffer.as_mut_ptr() as *mut c_char, buffer.len()) {
            return None;
        }
        let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
        let answer = String::from_utf8_lossy(&buffer[..end]).trim().to_string();
        if answer.is_empty() {
            None
        } else {
            Some(answer)
        }
    }
}

/// What Apple offers, as JSON for Swift.
/// `force_method` makes Swift ask HOW the code should be sent, whatever Apple already assumes.
fn describe(params: &TwoFactorCallbackParams, force_method: bool) -> String {
    let numbers: Vec<serde_json::Value> = params
        .numbers
        .iter()
        .map(|number| {
            serde_json::json!({
                "id": number.id,
                "label": number.number_with_dial_code,
                "mode": number.push_mode,
            })
        })
        .collect();
    serde_json::json!({
        "needsMethod": force_method || params.unknown,
        "sms": params.sms,
        "selectedNumber": params.selected_number_id,
        "numbers": numbers,
    })
    .to_string()
}

/// Swift's answer, as isideload understands it. Anything unclear cancels the sign-in.
fn answer_from(reply: Option<String>) -> TwoFactorCallbackResponse {
    let Some(reply) = reply else {
        return TwoFactorCallbackResponse::Abort;
    };
    if reply == "devices" {
        TwoFactorCallbackResponse::SendToDevices
    } else if reply == "resend" {
        TwoFactorCallbackResponse::ResendCode
    } else if let Some(id) = reply.strip_prefix("sms:").and_then(|id| id.parse::<u32>().ok()) {
        TwoFactorCallbackResponse::SendSms(id)
    } else if let Some(code) = reply.strip_prefix("code:") {
        TwoFactorCallbackResponse::SubmitCode(code.to_string())
    } else {
        TwoFactorCallbackResponse::Abort
    }
}

unsafe fn text(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    CStr::from_ptr(pointer).to_str().ok().map(str::to_owned)
}

/// Copies `message` into the buffer Swift gave, cut to fit and NUL-ended.
unsafe fn write_error(message: &str, buffer: *mut c_char, capacity: usize) {
    if buffer.is_null() || capacity == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let length = bytes.len().min(capacity - 1);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, length);
    *buffer.add(length) = 0;
}

/// Signs in. Returns a handle to the signed-in account, or null with the reason in `error`.
/// The handle goes to `koda_renewer_account_free` when done.
///
/// `storage_dir` is a folder the app may write to: isideload keeps the anisette state there (the
/// identity it presents to Apple). Its default is the current folder, which on an iPhone is read-only.
///
/// # Safety
/// `email`, `password` and `storage_dir` must be NUL-ended strings, `error` a buffer of
/// `error_capacity` bytes, and `user` valid until this function returns.
#[no_mangle]
pub unsafe extern "C" fn koda_renewer_login(
    email: *const c_char,
    password: *const c_char,
    storage_dir: *const c_char,
    callback: CodeCallback,
    user: *mut c_void,
    error: *mut c_char,
    error_capacity: usize,
) -> *mut AppleAccount {
    let (Some(email), Some(password)) = (text(email), text(password)) else {
        write_error("The Apple ID or the password was empty.", error, error_capacity);
        return std::ptr::null_mut();
    };
    let Some(storage_dir) = text(storage_dir) else {
        write_error("No folder was given to keep the sign-in state in.", error, error_capacity);
        return std::ptr::null_mut();
    };
    remember_panics();
    install_crypto();
    let context = Context { callback, user };
    // isideload asks the callback more than once: first HOW the code is to reach the person (the
    // trusted devices, or an SMS to one of the trusted numbers), and only then for the code itself
    // ("Cannot submit code without knowing which method to use"). Apple sends a code by itself as soon as
    // the password is accepted, so the method is asked about only when Apple says it doesn't know it
    // (`params.unknown`); otherwise the first question is already the code.
    // A panic anywhere in the sign-in would take the whole app down; it is caught and reported instead.
    let outcome = panic::catch_unwind(AssertUnwindSafe(|| {
        runtime().block_on(async move {
            // `default()` can fail (it builds an HTTP client), so it gives a Result.
            let provider = RemoteV3AnisetteProvider::default()?
                .set_storage(Box::new(FsStorage::new(PathBuf::from(storage_dir))));
            AppleAccount::builder(&email)
                .anisette_provider(provider)
                .login(&password, move |params| {
                    let request = describe(&params, false);
                    let method_request = describe(&params, true);
                    async move {
                        let mut request = request;
                        loop {
                            let ask = request.clone();
                            // Swift waits for the person to answer, so this must not hold up an async worker.
                            let reply = tokio::task::spawn_blocking(move || context.ask(&ask)).await.ok().flatten();
                            // "Change method" from the code window: ask for the method again.
                            if reply.as_deref() == Some("method") {
                                request = method_request.clone();
                                continue;
                            }
                            return Ok::<TwoFactorCallbackResponse, Report>(answer_from(reply));
                        }
                    }
                })
                .await
        })
    }));
    let result = match outcome {
        Ok(result) => result,
        Err(_) => {
            write_error(&format!("The renewal tool crashed: {}", last_panic()), error, error_capacity);
            return std::ptr::null_mut();
        }
    };
    match result {
        Ok(account) => Box::into_raw(Box::new(account)),
        Err(report) => {
            write_error(&format!("{report}"), error, error_capacity);
            std::ptr::null_mut()
        }
    }
}

/// # Safety
/// `account` must come from `koda_renewer_login` and not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn koda_renewer_account_free(account: *mut AppleAccount) {
    if !account.is_null() {
        drop(Box::from_raw(account));
    }
}

/// Reads what the Apple ID has in the developer service, without changing anything: its teams, the
/// development certificates on each, and how many app IDs are used (a free account has a weekly limit).
async fn read_account(account: &mut AppleAccount) -> Result<String, Report> {
    let mut session = DeveloperSession::from_account(account).await?;
    let teams = session.list_teams().await?;
    let mut found = Vec::new();
    for team in &teams {
        let certificates = session.list_ios_certs(team).await?;
        let app_ids = session.list_app_ids(team, DeveloperDeviceType::Ios).await?;
        let certificates: Vec<serde_json::Value> = certificates
            .iter()
            .map(|certificate| {
                serde_json::json!({
                    "name": certificate.name,
                    "serialNumber": certificate.serial_number,
                    "machine": certificate.machine_name,
                    "status": certificate.status,
                    "expires": certificate.expiration_date.as_ref().map(|date| date.to_xml_format()),
                })
            })
            .collect();
        found.push(serde_json::json!({
            "name": team.name,
            "teamId": team.team_id,
            "type": team.r#type,
            "status": team.status,
            "certificates": certificates,
            "appIDs": {
                "used": app_ids.app_ids.len(),
                "max": app_ids.max_quantity,
                "available": app_ids.available_quantity,
            },
        }));
    }
    Ok(serde_json::json!({ "teams": found }).to_string())
}

/// Reads the developer account of a signed-in Apple ID (stage 3, read-only). On success the answer is
/// JSON in `out`; otherwise false, with the reason in `error`.
///
/// # Safety
/// `account` must come from `koda_renewer_login`; `out` and `error` are buffers of their capacities.
#[no_mangle]
pub unsafe extern "C" fn koda_renewer_account_info(
    account: *mut AppleAccount,
    out: *mut c_char,
    out_capacity: usize,
    error: *mut c_char,
    error_capacity: usize,
) -> bool {
    remember_panics();
    install_crypto();
    if account.is_null() {
        write_error("There is no signed-in account.", error, error_capacity);
        return false;
    }
    let account = &mut *account;
    let outcome = panic::catch_unwind(AssertUnwindSafe(|| runtime().block_on(read_account(account))));
    let result = match outcome {
        Ok(result) => result,
        Err(_) => {
            write_error(&format!("The renewal tool crashed: {}", last_panic()), error, error_capacity);
            return false;
        }
    };
    match result {
        Ok(json) if json.len() < out_capacity => {
            write_error(&json, out, out_capacity);
            true
        }
        Ok(_) => {
            write_error("The answer was too long to hand over.", error, error_capacity);
            false
        }
        Err(report) => {
            write_error(&format!("{report}"), error, error_capacity);
            false
        }
    }
}

/// Makes a certificate and a profile for this iPhone on the Apple ID and signs a copy of the app at
/// `app_path` with them (stage 4). Returns the folder of the signed app.
///
/// Left at isideload's defaults on purpose: the first team, and an error (not revoking) when the
/// account is already at its certificate limit, because revoking a certificate stops every app that
/// was signed with it, Koda itself included.
async fn sign_own_app(
    account: &mut AppleAccount,
    email: String,
    udid: String,
    device_name: String,
    app_path: PathBuf,
    storage_dir: PathBuf,
) -> Result<String, Report> {
    let mut session = DeveloperSession::from_account(account).await?;
    let team = session.list_teams().await?.into_iter().next().ok_or_report()?;
    // Without the phone on the team there is no device to put in the profile (error 8220).
    session.ensure_device_registered(&team, &device_name, &udid, DeveloperDeviceType::Ios).await?;
    let mut sideloader = SideloaderBuilder::new(session, email)
        .storage(Box::new(FsStorage::new(storage_dir)))
        .machine_name("Koda".to_string())
        .build();
    let (signed, _) = sideloader
        .sign_app::<_, std::future::Ready<()>>(app_path, Some(team), false, None::<fn(f32) -> std::future::Ready<()>>, None, None)
        .await?;
    Ok(signed.to_string_lossy().to_string())
}

/// Signs a copy of the app (stage 4); the folder of the signed app goes into `out`. False, with the
/// reason in `error`, when something fails.
///
/// # Safety
/// `account` must come from `koda_renewer_login`; the strings are NUL-ended; `out` and `error` are
/// buffers of their capacities.
#[no_mangle]
pub unsafe extern "C" fn koda_renewer_sign_own_app(
    account: *mut AppleAccount,
    email: *const c_char,
    udid: *const c_char,
    device_name: *const c_char,
    app_path: *const c_char,
    storage_dir: *const c_char,
    out: *mut c_char,
    out_capacity: usize,
    error: *mut c_char,
    error_capacity: usize,
) -> bool {
    remember_panics();
    install_crypto();
    if account.is_null() {
        write_error("There is no signed-in account.", error, error_capacity);
        return false;
    }
    let (Some(email), Some(udid), Some(device_name), Some(app_path), Some(storage_dir)) =
        (text(email), text(udid), text(device_name), text(app_path), text(storage_dir))
    else {
        write_error("Something needed for signing was missing.", error, error_capacity);
        return false;
    };
    let account = &mut *account;
    let outcome = panic::catch_unwind(AssertUnwindSafe(|| {
        runtime().block_on(sign_own_app(
            account,
            email,
            udid,
            device_name,
            PathBuf::from(app_path),
            PathBuf::from(storage_dir),
        ))
    }));
    let result = match outcome {
        Ok(result) => result,
        Err(_) => {
            write_error(&format!("The renewal tool crashed: {}", last_panic()), error, error_capacity);
            return false;
        }
    };
    match result {
        Ok(path) if path.len() < out_capacity => {
            write_error(&path, out, out_capacity);
            true
        }
        Ok(_) => {
            write_error("The path of the signed app was too long to hand over.", error, error_capacity);
            false
        }
        Err(report) => {
            write_error(&format!("{report}"), error, error_capacity);
            false
        }
    }
}
