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
//! ├── device.rs   ← vendor rows + the device names that select them
//! └── apply.rs    ← applies a profile through `crate::susfs`
//! ```
//!
//! The list is deliberately data-only: [`catalog::ENTRIES`] and
//! [`device::PACKS`] are the only places a path is added or removed, and
//! [`apply`] never spells a path.

pub mod apply;
pub mod catalog;
pub mod device;
pub mod profile;

pub use apply::{apply, list, status};
pub use profile::HideProfile;

use anyhow::Result;

use crate::susfs_config;
use crate::susfs_config::keys::KEY_HIDE_PROFILE;

/// Level a device with no detected vendor pack and no stored choice starts at.
pub const DEFAULT_PROFILE: HideProfile = HideProfile::Balanced;

/// Read the stored profile.
///
/// An explicit `hide_profile` always wins, so a user who picked `light` keeps
/// it. With nothing stored the device decides — see [`default_profile`] — and
/// a corrupt stored value logs a warning and falls back to that instead of
/// quietly turning hiding off.
pub fn configured_profile() -> Result<HideProfile> {
    let raw = susfs_config::get(KEY_HIDE_PROFILE)?;
    if raw.trim().is_empty() {
        return Ok(default_profile());
    }
    Ok(HideProfile::parse(&raw).unwrap_or_else(|err| {
        let fallback = default_profile();
        log::warn!("hide: {err:#}, falling back to {}", fallback.as_str());
        fallback
    }))
}

/// The automatic level: the detected pack's, else [`DEFAULT_PROFILE`].
pub fn default_profile() -> HideProfile {
    device::detect().map_or(DEFAULT_PROFILE, |matched| matched.pack.default_profile)
}
