//! The curated hide table.
//!
//! One row per fingerprint a root detector can probe. `min` is the weakest
//! [`HideProfile`] that applies the row and `why` is what the row defeats;
//! `ksud hide list` prints both, so the table stays explainable and a row
//! that no longer matches a real probe is easy to spot and delete.
//!
//! Paths are literals rather than `crate::defs` constants: a detector
//! matches the on-disk spelling, and most rows (`/data/adb/magisk`,
//! `/data/adb/lspd`, …) belong to other projects and have no constant here.
//!
//! Every row is registered with `sus_path`, which filters path lookup. It
//! does not filter `/proc/<pid>/maps`, so this table provides no map-level
//! coverage: `sus_map` is a separate command with its own list, and it stays
//! a manual setting because a directory row would not cover the libraries
//! mapped out of it and a file row would have to name a `.so` whose path
//! differs per install.

use super::profile::HideProfile;

/// One fingerprint and the profile that hides it.
pub struct HideEntry {
    pub value: &'static str,
    pub min: HideProfile,
    pub why: &'static str,
}

pub(super) const fn path(value: &'static str, min: HideProfile, why: &'static str) -> HideEntry {
    HideEntry { value, min, why }
}

/// The table. Order is by profile so `ksud hide list` reads as a ramp.
pub const ENTRIES: &[HideEntry] = &[
    // ── light: nothing a stock app has any reason to read ───────────────────
    path(
        "/data/adb/ksu",
        HideProfile::Light,
        "KernelSU working dir: allowlist, logs, ksud, profile store",
    ),
    path(
        "/data/adb/ksud",
        HideProfile::Light,
        "KernelSU daemon binary",
    ),
    path(
        "/data/adb/modules",
        HideProfile::Light,
        "installed module store",
    ),
    path(
        "/data/adb/modules_update",
        HideProfile::Light,
        "staged module updates",
    ),
    path("/data/adb/magisk", HideProfile::Light, "Magisk data dir"),
    path(
        "/debug_ramdisk",
        HideProfile::Light,
        "Magisk daemon mount point",
    ),
    path(
        "/sbin/.magisk",
        HideProfile::Light,
        "Magisk legacy tmpfs mount",
    ),
    path("/system/bin/su", HideProfile::Light, "classic su location"),
    path("/system/xbin/su", HideProfile::Light, "classic su location"),
    path("/vendor/bin/su", HideProfile::Light, "vendor su location"),
    path("/sbin/su", HideProfile::Light, "classic su location"),
    // ── balanced: other root implementations and the injectors ──────────────
    path(
        "/data/adb/kpm",
        HideProfile::Balanced,
        "KernelSU KPM module store",
    ),
    path(
        "/data/adb/nyazygisk",
        HideProfile::Balanced,
        "legacy built-in Zygisk staging dir; current builds use /data/adb/ksu/zygisk",
    ),
    path(
        "/data/adb/lspd",
        HideProfile::Balanced,
        "LSPosed daemon dir",
    ),
    path(
        "/data/adb/zygisksu",
        HideProfile::Balanced,
        "Zygisk Next data dir",
    ),
    path("/data/adb/riru", HideProfile::Balanced, "Riru data dir"),
    path("/data/adb/ap", HideProfile::Balanced, "APatch data dir"),
    path("/data/adb/apd", HideProfile::Balanced, "APatch daemon"),
    path(
        "/data/adb/post-fs-data.d",
        HideProfile::Balanced,
        "Magisk-style boot scripts",
    ),
    path(
        "/data/adb/service.d",
        HideProfile::Balanced,
        "Magisk-style late boot scripts",
    ),
    path(
        "/init.magisk.rc",
        HideProfile::Balanced,
        "Magisk init script",
    ),
    path("/cache/magisk.log", HideProfile::Balanced, "Magisk log"),
    path(
        "/dev/.magisk.unblock",
        HideProfile::Balanced,
        "Magisk unblock marker",
    ),
    // ── aggressive: the whole tree, including anything added later ──────────
    path(
        "/data/adb",
        HideProfile::Aggressive,
        "every root implementation's home, and every future subdirectory of it",
    ),
];
