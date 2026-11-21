//! Apply a [`HideProfile`] through the SuSFS kernel ABI.

use std::fmt::Write as FmtWrite;
use std::path::Path;

use anyhow::{Result, bail};

use super::catalog::{ENTRIES, HideEntry};
use super::profile::HideProfile;
use crate::susfs;

/// One entry that could not be applied, with the reason.
pub struct HideSkip {
    pub value: &'static str,
    pub reason: String,
}

/// Outcome of one `ksud hide apply`.
pub struct HideReport {
    pub profile: HideProfile,
    pub applied: usize,
    pub skipped: Vec<HideSkip>,
}

impl HideReport {
    /// Summary line plus one line per skipped entry.
    pub fn render(&self) -> String {
        let mut out = format!(
            "hide: {} — {} applied, {} skipped\n",
            self.profile.as_str(),
            self.applied,
            self.skipped.len()
        );
        for skip in &self.skipped {
            let _ = writeln!(out, "  skipped {}: {}", skip.value, skip.reason);
        }
        out
    }
}

/// Apply every catalog entry the profile covers.
///
/// Errors only when SuSFS itself is unavailable, because then nothing can
/// be applied at all. A single missing path is a skip instead: most entries
/// belong to optional modules and are absent by design, so one absent row
/// must not abort the rest. A row the kernel refuses is also a skip, never a
/// success, so the counts never claim a hide that was not registered.
pub fn apply(profile: HideProfile) -> Result<HideReport> {
    if profile == HideProfile::Off {
        return Ok(HideReport {
            profile,
            applied: 0,
            skipped: Vec::new(),
        });
    }
    if !susfs::get_susfs_status() {
        bail!("SuSFS is not available on this kernel, nothing can be hidden");
    }

    let mut report = HideReport {
        profile,
        applied: 0,
        skipped: Vec::new(),
    };
    for entry in ENTRIES.iter().filter(|entry| profile.covers(entry.min)) {
        match apply_entry(entry) {
            Ok(()) => report.applied += 1,
            Err(reason) => report.skipped.push(HideSkip {
                value: entry.value,
                reason,
            }),
        }
    }
    Ok(report)
}

/// Apply one entry, mapping a failure to the reason shown to the user.
fn apply_entry(entry: &HideEntry) -> std::result::Result<(), String> {
    if !Path::new(entry.value).exists() {
        return Err("not present".to_string());
    }
    susfs::add_sus_path(entry.value).map_err(|err| err.to_string())
}

/// The stored profile, the SuSFS state behind it, and how many entries the
/// profile would apply. Read-only, for `ksud hide status`.
pub fn status() -> Result<String> {
    let profile = super::configured_profile()?;
    let mut out = format!("profile: {}\n", profile.as_str());
    if !susfs::get_susfs_status() {
        out.push_str("susfs: unavailable\n");
        return Ok(out);
    }
    let _ = writeln!(out, "susfs: available");
    let _ = writeln!(out, "version: {}", susfs::get_susfs_version());
    let _ = writeln!(out, "variant: {}", susfs::get_susfs_variant());
    let _ = writeln!(
        out,
        "entries: {}",
        ENTRIES
            .iter()
            .filter(|entry| profile.covers(entry.min))
            .count()
    );
    Ok(out)
}

/// Render the catalog, marking the entries `profile` applies.
pub fn list(profile: HideProfile) -> String {
    let mut out = String::new();
    for entry in ENTRIES {
        let mark = if profile.covers(entry.min) { 'x' } else { ' ' };
        let _ = writeln!(
            out,
            "[{mark}] {:<26} from {:<10} {}",
            entry.value,
            entry.min.as_str(),
            entry.why
        );
    }
    out
}
