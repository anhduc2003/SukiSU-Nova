//! Apply a [`HideProfile`] through the SuSFS kernel ABI.

use std::fmt::Write as FmtWrite;
use std::path::Path;

use anyhow::{Result, bail};

use super::catalog::{ENTRIES, HideEntry};
use super::device;
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
    /// Vendor pack that contributed rows, when one matched.
    pub device: Option<&'static str>,
    pub applied: usize,
    pub skipped: Vec<HideSkip>,
}

impl HideReport {
    /// Summary line plus one line per skipped entry.
    pub fn render(&self) -> String {
        let mut out = format!(
            "hide: {} — {} applied, {} skipped",
            self.profile.as_str(),
            self.applied,
            self.skipped.len()
        );
        if let Some(device) = self.device {
            let _ = write!(out, " ({device})");
        }
        out.push('\n');
        for skip in &self.skipped {
            let _ = writeln!(out, "  skipped {}: {}", skip.value, skip.reason);
        }
        out
    }
}

/// The rows a profile applies: the catalog plus any vendor pack that matched.
fn rows(profile: HideProfile, matched: Option<&device::DeviceMatch>) -> Vec<&'static HideEntry> {
    let vendor: &'static [HideEntry] = matched.map_or(&[], |matched| matched.pack.rows);
    ENTRIES
        .iter()
        .chain(vendor.iter())
        .filter(|entry| profile.covers(entry.min))
        .collect()
}

/// Apply every row the profile covers.
///
/// Errors only when SuSFS itself is unavailable, because then nothing can be
/// applied at all. A single missing path is a skip instead: most entries
/// belong to optional modules and are absent by design, so one absent row
/// must not abort the rest. A row the kernel refuses is also a skip, never a
/// success, so the counts never claim a hide that was not registered.
pub fn apply(profile: HideProfile) -> Result<HideReport> {
    let matched = device::detect();
    if profile == HideProfile::Off {
        return Ok(HideReport {
            profile,
            device: matched.as_ref().map(|matched| matched.pack.name),
            applied: 0,
            skipped: Vec::new(),
        });
    }
    if !susfs::get_susfs_status() {
        bail!("SuSFS is not available on this kernel, nothing can be hidden");
    }

    let mut report = HideReport {
        profile,
        device: matched.as_ref().map(|matched| matched.pack.name),
        applied: 0,
        skipped: Vec::new(),
    };
    for entry in rows(profile, matched.as_ref()) {
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

/// The stored profile, the device that shaped it, and the SuSFS state behind
/// it. Read-only, for `ksud hide status`.
pub fn status() -> Result<String> {
    let matched = device::detect();
    let automatic = susfs_config_is_automatic()?;
    let profile = super::configured_profile()?;

    let mut out = format!("profile: {}", profile.as_str());
    if automatic {
        out.push_str(" (automatic)");
    }
    out.push('\n');
    if let Some(matched) = &matched {
        let _ = writeln!(out, "device: {} [{}]", matched.pack.name, matched.device);
    }
    if !susfs::get_susfs_status() {
        out.push_str("susfs: unavailable\n");
        return Ok(out);
    }
    let _ = writeln!(out, "susfs: available");
    let _ = writeln!(out, "version: {}", susfs::get_susfs_version());
    let _ = writeln!(out, "variant: {}", susfs::get_susfs_variant());
    let _ = writeln!(out, "entries: {}", rows(profile, matched.as_ref()).len());
    Ok(out)
}

/// `true` when no `hide_profile` is stored, i.e. the device picked the level.
fn susfs_config_is_automatic() -> Result<bool> {
    Ok(
        crate::susfs_config::get(crate::susfs_config::keys::KEY_HIDE_PROFILE)?
            .trim()
            .is_empty(),
    )
}

/// Render the catalog and the device rows, marking what `profile` applies.
pub fn list(profile: HideProfile) -> String {
    let matched = device::detect();
    let mut out = String::new();
    for entry in ENTRIES {
        push_row(&mut out, entry, profile);
    }
    if let Some(matched) = &matched {
        let _ = writeln!(out, "# {}", matched.pack.name);
        for entry in matched.pack.rows {
            push_row(&mut out, entry, profile);
        }
    }
    out
}

fn push_row(out: &mut String, entry: &HideEntry, profile: HideProfile) {
    let mark = if profile.covers(entry.min) { 'x' } else { ' ' };
    let _ = writeln!(
        out,
        "[{mark}] {:<26} from {:<10} {}",
        entry.value,
        entry.min.as_str(),
        entry.why
    );
}
