//! Koda's own renewal tool, Rust side. Stage 2a: sign in to an Apple ID (with two-factor) through
//! isideload. Swift calls these C functions from a background thread; each one blocks until done.
//! Pairing, signing Koda and installing it come in later stages.
//!
//! API as of isideload 0.5.2 (docs.rs/isideload/0.5.2): `AppleAccount::builder(email).login(password,
//! callback)`, where the callback is asked for a two-factor code and answers a `TwoFactorCallbackResponse`.

use std::ffi::{c_char, c_void, CStr};
use std::path::PathBuf;
use std::panic::{self, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Once, OnceLock};

use isideload::anisette::remote_v3::RemoteV3AnisetteProvider;
use isideload::auth::apple_account::{AppleAccount, TwoFactorCallbackResponse};
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

/// Asked for the two-factor code. Swift writes it into `buffer` (UTF-8, NUL-ended, at most
/// `capacity` bytes) and returns true, or returns false to cancel the sign-in.
pub type CodeCallback = extern "C" fn(user: *mut c_void, buffer: *mut c_char, capacity: usize) -> bool;

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
    fn ask(self) -> Option<String> {
        let mut buffer = vec![0u8; 64];
        if !(self.callback)(self.user, buffer.as_mut_ptr() as *mut c_char, buffer.len()) {
            return None;
        }
        let end = buffer.iter().position(|byte| *byte == 0).unwrap_or(buffer.len());
        let code = String::from_utf8_lossy(&buffer[..end]).trim().to_string();
        if code.is_empty() {
            None
        } else {
            Some(code)
        }
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
    // isideload asks the callback more than once. The first time it wants to know HOW the code
    // is to reach the person (to the trusted devices, or by SMS); only then does it accept the code
    // ("Cannot submit code without knowing which method to use"). So: first call, choose the
    // trusted devices; the calls after that ask Swift for the code.
    let calls = Arc::new(AtomicUsize::new(0));
    // A panic anywhere in the sign-in would take the whole app down; it is caught and reported instead.
    let outcome = panic::catch_unwind(AssertUnwindSafe(|| {
        runtime().block_on(async move {
            // `default()` can fail (it builds an HTTP client), so it gives a Result.
            let provider = RemoteV3AnisetteProvider::default()?
                .set_storage(Box::new(FsStorage::new(PathBuf::from(storage_dir))));
            AppleAccount::builder(&email)
                .anisette_provider(provider)
                .login(&password, move |_params| {
                    let first = calls.fetch_add(1, Ordering::SeqCst) == 0;
                    async move {
                        if first {
                            return Ok::<TwoFactorCallbackResponse, Report>(TwoFactorCallbackResponse::SendToDevices);
                        }
                        // Swift waits for the person to type the code, so this must not hold up an async worker.
                        let code = tokio::task::spawn_blocking(move || context.ask()).await.ok().flatten();
                        Ok(match code {
                            Some(code) => TwoFactorCallbackResponse::SubmitCode(code),
                            None => TwoFactorCallbackResponse::Abort,
                        })
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
