//! Built-in root-hiding packs.
//!
//! A detector's first move is to look for the files root leaves behind:
//! `/data/adb/ksu`, `/data/adb/modules`, `su`, the LSPosed and Zygisk daemon
//! directories. SuSFS can hide any of those, but only once someone names
//! them, so `ksud` ships a curated list and applies it in one step instead
//! of asking every user to build the list by hand.
//!
//! ## Layout
//!
//! ```text
//! hide/
//! ├── mod.rs      ← you are here: public re-exports only
//! ├── profile.rs  ← HideProfile (off / light / balanced / aggressive)
//! ├── catalog.rs  ← the curated entry table, one row per fingerprint
//! └── apply.rs    ← applies a profile through `crate::susfs`
//! ```
//!
//! The list is deliberately data-only: [`catalog::ENTRIES`] is the single
//! place a path is added or removed, and [`apply`] never spells a path.

pub mod apply;
pub mod catalog;
pub mod profile;

pub use apply::{apply, list, status};
pub use profile::HideProfile;

use anyhow::Result;

use crate::susfs_config;
use crate::susfs_config::keys::KEY_HIDE_PROFILE;

/// Profile applied when the config key is missing or empty.
///
/// Upgrading an existing install has no stored key, so the default is the
/// level that covers the paths real detectors probe; `off` is the opt-out.
pub const DEFAULT_PROFILE: HideProfile = HideProfile::Balanced;

/// Read the stored profile, falling back to [`DEFAULT_PROFILE`].
pub fn configured_profile() -> Result<HideProfile> {
    Ok(profile_or_default(&susfs_config::get(KEY_HIDE_PROFILE)?))
}

/// Interpret a stored config value, falling back to [`DEFAULT_PROFILE`]
/// when it is empty or unreadable.
///
/// The fallback is deliberately silent about a *missing* key (an install
/// that predates the key) and loud about a *corrupt* one, so a typo in the
/// config file shows up in the log instead of quietly disabling hiding.
pub fn profile_or_default(raw: &str) -> HideProfile {
    if raw.trim().is_empty() {
        return DEFAULT_PROFILE;
    }
    HideProfile::parse(raw).unwrap_or_else(|err| {
        log::warn!(
            "hide: {err:#}, falling back to {}",
            DEFAULT_PROFILE.as_str()
        );
        DEFAULT_PROFILE
    })
}
