//! SuSFS path / map / redirect operations.

use crate::susfs::abi::consts::{
    CMD_SUSFS_ADD_OPEN_REDIRECT, CMD_SUSFS_ADD_SUS_MAP, CMD_SUSFS_ADD_SUS_PATH,
    CMD_SUSFS_ADD_SUS_PATH_LOOP, ERR_CMD_NOT_SUPPORTED, SUSFS_MAX_PATHNAME,
};
use crate::susfs::abi::{SusfsMap, SusfsOpenRedirect, SusfsSusPath, send, send_errno};
use crate::susfs::util::copy_path_into;

/// Mark `path` as a SuSFS hidden path.
///
/// Re-adding a path that is already hidden succeeds: the boot scripts apply
/// the same list every boot, and `EEXIST` there means the hide is already in
/// place rather than that anything went wrong.
pub fn add_sus_path(path: &str) -> anyhow::Result<()> {
    let mut cmd = SusfsSusPath {
        target_pathname: [0; SUSFS_MAX_PATHNAME],
        err: ERR_CMD_NOT_SUPPORTED,
    };
    copy_path_into(&mut cmd.target_pathname, path)?;
    check_path_result(send_errno(CMD_SUSFS_ADD_SUS_PATH, &mut cmd), "add_sus_path")
}

/// Like [`add_sus_path`] but also follows the path across bind mounts.
pub fn add_sus_path_loop(path: &str) -> anyhow::Result<()> {
    let mut cmd = SusfsSusPath {
        target_pathname: [0; SUSFS_MAX_PATHNAME],
        err: ERR_CMD_NOT_SUPPORTED,
    };
    copy_path_into(&mut cmd.target_pathname, path)?;
    send(CMD_SUSFS_ADD_SUS_PATH_LOOP, &mut cmd, "add_sus_path_loop")
}

/// Add an `open()`-time redirect: `target` paths will be silently opened
/// as `redirected` for processes selected by `uid_scheme`.
pub fn add_open_redirect(target: &str, redirected: &str, uid_scheme: u32) -> anyhow::Result<()> {
    let mut cmd = SusfsOpenRedirect {
        target_pathname: [0; SUSFS_MAX_PATHNAME],
        redirected_pathname: [0; SUSFS_MAX_PATHNAME],
        uid_scheme,
        err: ERR_CMD_NOT_SUPPORTED,
    };
    copy_path_into(&mut cmd.target_pathname, target)?;
    copy_path_into(&mut cmd.redirected_pathname, redirected)?;
    send(CMD_SUSFS_ADD_OPEN_REDIRECT, &mut cmd, "add_open_redirect")
}

/// Add `path` to the SuSFS map of overlay / mount roots.
///
/// Like [`add_sus_path`], re-adding an entry that is already mapped succeeds.
pub fn add_sus_map(path: &str) -> anyhow::Result<()> {
    let mut cmd = SusfsMap {
        target_pathname: [0; SUSFS_MAX_PATHNAME],
        err: ERR_CMD_NOT_SUPPORTED,
    };
    copy_path_into(&mut cmd.target_pathname, path)?;
    check_path_result(send_errno(CMD_SUSFS_ADD_SUS_MAP, &mut cmd), "add_sus_map")
}

/// Shared result mapping for the two commands whose payload is a single
/// `target_pathname`.
///
/// A kernel that has SuSFS but was built without the matching
/// `CONFIG_KSU_SUSFS_*` option answers [`ERR_CMD_NOT_SUPPORTED`], which is a
/// real failure here: reporting it as success would claim a hide that the
/// kernel never registered.
fn check_path_result(err: i32, op_name: &str) -> anyhow::Result<()> {
    if err == 0 || err == -libc::EEXIST {
        return Ok(());
    }
    if err == ERR_CMD_NOT_SUPPORTED {
        anyhow::bail!(
            "{op_name}: kernel does not implement this command (SuSFS option not compiled in)"
        );
    }
    anyhow::bail!("{op_name}: kernel returned err={err}")
}
