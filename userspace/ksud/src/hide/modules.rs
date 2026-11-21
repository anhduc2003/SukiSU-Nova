//! Configuration written into the hiding modules that are installed.
//!
//! Each module is detected by the data directory it documents, not by a
//! module id, because the id changes between forks while the directory does
//! not. Only settings that are plain text lists and take effect immediately
//! are written. Anything that needs a secret — a keybox, a device
//! fingerprint — is reported as missing rather than invented, and Shamiko's
//! whitelist mode is reported but never switched on: it stops every newly
//! installed app from being granted root until the marker file is removed,
//! which is not a change to make behind someone's back.
//!
//! [`inspect`] only reads, so `ksud hide status` stays a query; [`integrate`]
//! is the writing half and is called from `ksud hide apply`.

use std::fmt::Write as FmtWrite;
use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

const TRICKY_STORE_DIR: &str = "/data/adb/tricky_store";
const SHAMIKO_DIR: &str = "/data/adb/shamiko";
const ZYGISK_NEXT_DIR: &str = "/data/adb/zygisksu";
const LSPOSED_DIR: &str = "/data/adb/lspd";
const RIRU_DIR: &str = "/data/adb/riru";
const APATCH_DIR: &str = "/data/adb/ap";
const KPM_DIR: &str = "/data/adb/kpm";
const BUILTIN_ZYGISK_DIR: &str = "/data/adb/nyazygisk";

/// Packages that run Play Integrity attestation, which is what a banking app
/// actually asks. TrickyStore only spoofs the packages listed in
/// `target.txt`, so without these two entries the module does nothing for
/// them.
const ATTESTATION_TARGETS: &[&str] = &["com.google.android.gms", "com.android.vending"];

/// One module this fork knows how to hide, and what it needs from the user.
pub struct ModuleRow {
    pub name: &'static str,
    pub path: &'static str,
    pub advice: &'static str,
}

/// Every module the catalog hides a directory for.
///
/// Four of them are third-party and nothing installs them for you — Riru and
/// APatch would actively conflict, and Zygisk Next duplicates the Zygisk this
/// fork already ships. The last two are SukiSU's own stores, created when the
/// matching feature is switched on in the manager.
const KNOWN_MODULES: &[ModuleRow] = &[
    ModuleRow {
        name: "TrickyStore",
        path: TRICKY_STORE_DIR,
        advice: "`hide apply` adds the attestation targets; STRONG needs keybox.xml",
    },
    ModuleRow {
        name: "Shamiko",
        path: SHAMIKO_DIR,
        advice: "optional; its whitelist mode blocks root for newly installed apps",
    },
    ModuleRow {
        name: "Zygisk Next",
        path: ZYGISK_NEXT_DIR,
        advice: "not needed; built-in Zygisk covers it and running both conflicts",
    },
    ModuleRow {
        name: "LSPosed",
        path: LSPOSED_DIR,
        advice: "only for Xposed modules; scope is per-app in its manager",
    },
    ModuleRow {
        name: "Riru",
        path: RIRU_DIR,
        advice: "superseded by Zygisk",
    },
    ModuleRow {
        name: "APatch",
        path: APATCH_DIR,
        advice: "a different root solution; it conflicts with KernelSU",
    },
    ModuleRow {
        name: "KPM store",
        path: KPM_DIR,
        advice: "built into SukiSU; enable KPM in the manager",
    },
    ModuleRow {
        name: "Built-in Zygisk",
        path: BUILTIN_ZYGISK_DIR,
        advice: "built into SukiSU; enable it in the manager",
    },
];

/// Render the inventory: every known module, installed or not.
///
/// This is what `ksud hide modules` prints, so "is this set up automatically"
/// has an answer on the device rather than only in the documentation.
pub fn inventory() -> String {
    let mut out = String::new();
    for row in KNOWN_MODULES {
        let state = if Path::new(row.path).is_dir() {
            "installed"
        } else {
            "absent"
        };
        let _ = writeln!(
            out,
            "{:<16} {:<24} {:<9} {}",
            row.name, row.path, state, row.advice
        );
    }
    out
}

/// What one installed module contributes, or what it still needs.
pub struct ModuleNote {
    pub module: &'static str,
    pub note: String,
}

/// Report the installed modules without changing anything.
pub fn inspect() -> Vec<ModuleNote> {
    collect(false)
}

/// Report the installed modules and apply the settings each one exposes.
pub fn integrate() -> Vec<ModuleNote> {
    collect(true)
}

fn collect(write: bool) -> Vec<ModuleNote> {
    let mut notes = Vec::new();
    if Path::new(TRICKY_STORE_DIR).is_dir() {
        notes.push(tricky_store(write));
    }
    if Path::new(SHAMIKO_DIR).is_dir() {
        notes.push(ModuleNote {
            module: "Shamiko",
            note: format!(
                "{}; whitelist mode is left off because it blocks root for newly installed apps",
                if Path::new(SHAMIKO_DIR).join("whitelist").exists() {
                    "already in whitelist mode"
                } else {
                    "blacklist mode"
                }
            ),
        });
    }
    if Path::new(ZYGISK_NEXT_DIR).is_dir() {
        notes.push(ModuleNote {
            module: "Zygisk Next",
            note: "present; it has no on-disk hiding setting, it follows the kernel denylist"
                .to_string(),
        });
    }
    if Path::new(LSPOSED_DIR).is_dir() {
        notes.push(ModuleNote {
            module: "LSPosed",
            note: "present; module scope is per-app, set it in the LSPosed manager".to_string(),
        });
    }
    if Path::new(RIRU_DIR).is_dir() {
        notes.push(ModuleNote {
            module: "Riru",
            note: "present; superseded by Zygisk, nothing to configure".to_string(),
        });
    }
    if Path::new(APATCH_DIR).is_dir() {
        notes.push(ModuleNote {
            module: "APatch",
            note: "present; another root implementation is installed alongside this one"
                .to_string(),
        });
    }
    notes
}

/// Report the attestation targets TrickyStore is missing, and add them when
/// `write` is set.
fn tricky_store(write: bool) -> ModuleNote {
    let dir = Path::new(TRICKY_STORE_DIR);
    let target = dir.join("target.txt");
    let mut note = match sync_targets(&target, ATTESTATION_TARGETS, write) {
        Ok(synced) if synced.is_empty() => {
            "target.txt already lists the attestation packages".to_string()
        }
        Ok(synced) if write => format!("added {} to target.txt", synced.join(", ")),
        Ok(synced) => format!(
            "target.txt is missing {}; `ksud hide apply` adds it",
            synced.join(", ")
        ),
        Err(err) => format!("could not update target.txt: {err}"),
    };
    if !dir.join("keybox.xml").is_file() {
        let _ = write!(
            note,
            "; no keybox.xml, so only the certificate-chain workaround is available and STRONG integrity needs a keybox"
        );
    }
    ModuleNote {
        module: "TrickyStore",
        note,
    }
}

/// Add the `wanted` packages that `path` does not already cover, returning
/// what was (or, without `write`, would be) added.
///
/// A line may carry a `!` or `?` suffix that selects a per-target mode, so a
/// package counts as present when its name matches with the suffix stripped;
/// appending a second bare line for it would override the user's choice.
fn sync_targets(
    path: &Path,
    wanted: &[&'static str],
    write: bool,
) -> io::Result<Vec<&'static str>> {
    // A missing file starts empty; any other read error aborts instead of
    // being treated as empty, because writing the result back would drop the
    // entries the user already has.
    let existing = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(err) if err.kind() == io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(err),
    };
    let missing: Vec<&'static str> = wanted
        .iter()
        .copied()
        .filter(|name| {
            !existing
                .lines()
                .any(|line| line.trim().trim_end_matches(['!', '?']) == *name)
        })
        .collect();
    if missing.is_empty() || !write {
        return Ok(missing);
    }

    let mut out = existing;
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
    for name in &missing {
        out.push_str(name);
        out.push('\n');
    }

    fs::create_dir_all(path.parent().unwrap_or_else(|| Path::new(TRICKY_STORE_DIR)))?;
    fs::write(path, out)?;
    // TrickyStore reads the file as the module's own uid, so keep it world
    // readable the way the module's installer leaves it.
    fs::set_permissions(path, fs::Permissions::from_mode(0o644))?;
    Ok(missing)
}

/// Render the notes as report lines.
pub fn render(notes: &[ModuleNote], indent: &str) -> String {
    let mut out = String::new();
    for note in notes {
        let _ = writeln!(out, "{indent}{}: {}", note.module, note.note);
    }
    out
}
