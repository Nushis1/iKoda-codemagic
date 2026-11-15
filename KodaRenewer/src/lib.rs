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
fn describe(params: &TwoFactorCallbackParams) -> String {
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
        "needsMethod": params.unknown,
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
    // ("Cannot submit code without knowing which method to use"). Swift asks the person each time.
    // A panic anywhere in the sign-in would take the whole app down; it is caught and reported instead.
    let outcome = panic::catch_unwind(AssertUnwindSafe(|| {
        runtime().block_on(async move {
            // `default()` can fail (it builds an HTTP client), so it gives a Result.
            let provider = RemoteV3AnisetteProvider::default()?
                .set_storage(Box::new(FsStorage::new(PathBuf::from(storage_dir))));
            AppleAccount::builder(&email)
                .anisette_provider(provider)
                .login(&password, move |params| {
                    let request = describe(&params);
                    async move {
                        // Swift waits for the person to answer, so this must not hold up an async worker.
                        let reply = tokio::task::spawn_blocking(move || context.ask(&request)).await.ok().flatten();
                        Ok::<TwoFactorCallbackResponse, Report>(answer_from(reply))
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
