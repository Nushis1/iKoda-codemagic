//! Stage 1: only proves that the sideloading crates compile and link for iOS.
//! The real entry points (sign in, pair, sign Koda, install it) come in the next stages.

use idevice as _;
use isideload as _;

/// Returns 1 when the library is linked in. Swift can call it to check.
#[no_mangle]
pub extern "C" fn koda_renewer_ping() -> u32 {
    1
}
