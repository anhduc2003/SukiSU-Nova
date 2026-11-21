//! Vendor-specific hide rows.
//!
//! The catalog covers what every rooted Android leaves behind. A vendor adds
//! its own storage on top, and ColorOS — what the OnePlus Ace 5 runs — keeps
//! OPLUS's own state under `/data/oplus` and `/data/oppo`, so those are the
//! extra rows here.
//!
//! Detection reads `ro.product.device` and its vendor/odm/product twins
//! rather than `ro.product.model`, because a rebranded twin shares the device
//! name: the OnePlus 13R is the same `giulia` hardware sold outside China.

use std::sync::OnceLock;

use prop_rs_android::resetprop::ResetProp;
use prop_rs_android::sys_prop;

use super::catalog::{HideEntry, path};
use super::profile::HideProfile;

/// One vendor's extra rows and the device names that select them.
pub struct DevicePack {
    /// Shown by `ksud hide status`.
    pub name: &'static str,
    /// Level a device with no stored `hide_profile` starts at.
    pub default_profile: HideProfile,
    /// `ro.product.device` values that select this pack.
    pub devices: &'static [&'static str],
    pub rows: &'static [HideEntry],
}

/// The pack matched on this device, plus the name that matched.
pub struct DeviceMatch {
    pub pack: &'static DevicePack,
    pub device: String,
}

/// Device-name properties, most specific first.
const DEVICE_PROPS: &[&str] = &[
    "ro.product.device",
    "ro.product.vendor.device",
    "ro.product.odm.device",
    "ro.product.product.device",
];

/// Every pack, in lookup order.
const PACKS: &[DevicePack] = &[DevicePack {
    name: "OnePlus Ace 5 (ColorOS)",
    // ColorOS ships its own security centre, so a device with no stored
    // choice starts at the strongest level rather than the generic default.
    default_profile: HideProfile::Aggressive,
    // `giuliac` is the China build, `giulia` the global one (OnePlus 13R).
    devices: &["giulia", "giuliac"],
    rows: &[
        path(
            "/data/oplus",
            HideProfile::Balanced,
            "OPLUS/ColorOS data dir read by the security centre",
        ),
        path("/data/oppo", HideProfile::Balanced, "legacy OPPO data dir"),
    ],
}];

/// Match the running device against [`PACKS`].
///
/// Returns `None` when no device property can be read, so a device whose
/// property API is unavailable simply gets the plain catalog.
pub fn detect() -> Option<DeviceMatch> {
    let names: Vec<String> = DEVICE_PROPS
        .iter()
        .filter_map(|name| read_prop(name))
        .collect();
    PACKS.iter().find_map(|pack| {
        names
            .iter()
            .find(|device| {
                pack.devices
                    .iter()
                    .any(|known| known.eq_ignore_ascii_case(device))
            })
            .map(|device| DeviceMatch {
                pack,
                device: device.clone(),
            })
    })
}

/// Read one system property, initialising the property API on first use.
fn read_prop(name: &str) -> Option<String> {
    static READY: OnceLock<bool> = OnceLock::new();
    if !*READY.get_or_init(|| sys_prop::init().is_ok()) {
        return None;
    }
    ResetProp {
        skip_svc: true,
        persistent: false,
        persist_only: false,
        verbose: false,
        show_context: false,
        rebuild: false,
    }
    .get(name)
    .filter(|value| !value.is_empty())
}
