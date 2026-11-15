// C interface of KodaRenewer (Rust). Written by hand to match src/lib.rs.
#ifndef KODA_RENEWER_H
#define KODA_RENEWER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque: a signed-in Apple ID account.
typedef struct KodaAccount KodaAccount;

/// Asked for the two-factor code. Write it into `buffer` (UTF-8, NUL-ended, at most `capacity`
/// bytes) and return true, or return false to cancel. Called on a background thread; may block.
typedef bool (*KodaCodeCallback)(void *user, char *buffer, size_t capacity);

uint32_t koda_renewer_ping(void);

/// Call once at the start. False if it could not set itself up.
bool koda_renewer_init(void);

/// Signs in. Returns the account, or NULL with the reason in `error`. Blocks: call it off the main thread.
/// `storage_dir` is a folder the app can write to; the anisette state is kept there.
KodaAccount *koda_renewer_login(const char *email, const char *password, const char *storage_dir,
                                KodaCodeCallback callback, void *user, char *error, size_t error_capacity);

void koda_renewer_account_free(KodaAccount *account);

#ifdef __cplusplus
}
#endif

#endif
