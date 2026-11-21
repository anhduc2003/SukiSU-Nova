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

/// Packages that run Play Integrity attestation, which is what a banking app
/// actually asks. TrickyStore only spoofs the packages listed in
/// `target.txt`, so without these two entries the module does nothing for
/// them.
const ATTESTATION_TARGETS: &[&str] = &["com.google.android.gms", "com.android.vending"];

/// What one installed module contributes, or what it still needs.
pub struct ModuleNote {
    pub module: &'static str,
    pub note: String,
}

/// Integrate with every hiding module found on this device.
pub fn integrate() -> Vec<ModuleNote> {
    let mut notes = Vec::new();
    if Path::new(TRICKY_STORE_DIR).is_dir() {
        notes.push(tricky_store());
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

/// Ensure `target.txt` lists the attestation packages, and report whether a
/// keybox is available for STRONG integrity.
fn tricky_store() -> ModuleNote {
    let dir = Path::new(TRICKY_STORE_DIR);
    let target = dir.join("target.txt");
    let mut note = match add_targets(&target, ATTESTATION_TARGETS) {
        Ok(added) if added.is_empty() => {
            "target.txt already lists the attestation packages".to_string()
        }
        Ok(added) => format!("added {} to target.txt", added.join(", ")),
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

/// Append the `wanted` packages that `path` does not already cover.
///
/// A line may carry a `!` or `?` suffix that selects a per-target mode, so a
/// package counts as present when its name matches with the suffix stripped;
/// appending a second bare line for it would override the user's choice.
fn add_targets(path: &Path, wanted: &[&'static str]) -> io::Result<Vec<&'static str>> {
    // A missing file starts empty; any other read error aborts instead of
    // being treated as empty, because writing the result back would drop the
    // entries the user already has.
    let existing = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(err) if err.kind() == io::ErrorKind::NotFound => String::new(),
        Err(err) => return Err(err),
    };
    let present = |name: &str| {
        existing
            .lines()
            .any(|line| line.trim().trim_end_matches(['!', '?']) == name)
    };
    let missing: Vec<&'static str> = wanted
        .iter()
        .copied()
        .filter(|name| !present(name))
        .collect();
    if missing.is_empty() {
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
