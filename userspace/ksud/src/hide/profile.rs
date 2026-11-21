//! Hide profiles: how much of the catalog gets applied.
//!
//! A profile is an ordered strength, not a separate list: every level
//! contains the ones below it, so raising the level only ever adds hides.

use anyhow::Result;

/// Strength of the built-in hide pack.
///
/// An entry in [`super::catalog::ENTRIES`] names the weakest profile that
/// applies it, which keeps the decision "how much do I want hidden" in one
/// place instead of spreading it over the table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub enum HideProfile {
    /// Apply nothing.
    Off = 0,
    /// Only paths no stock app reads: the KernelSU working directory, the
    /// module stores and the classic `su` locations.
    Light = 1,
    /// Light plus the other root implementations and the injection daemons
    /// (LSPosed, Zygisk Next, APatch) that detectors enumerate.
    Balanced = 2,
    /// Balanced plus the whole `/data/adb` tree, so a root directory added
    /// later is covered without a table change.
    Aggressive = 3,
}

impl HideProfile {
    /// Every profile, weakest first. Used by `ksud hide list` and by the
    /// error [`parse`](Self::parse) returns.
    pub const ALL: [Self; 4] = [Self::Off, Self::Light, Self::Balanced, Self::Aggressive];

    /// Name stored in the config file and accepted on the command line.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::Light => "light",
            Self::Balanced => "balanced",
            Self::Aggressive => "aggressive",
        }
    }

    /// Parse a profile name, ignoring case and surrounding whitespace.
    pub fn parse(value: &str) -> Result<Self> {
        let wanted = value.trim();
        Self::ALL
            .into_iter()
            .find(|profile| profile.as_str().eq_ignore_ascii_case(wanted))
            .ok_or_else(|| {
                let names: Vec<&str> = Self::ALL.iter().map(|profile| profile.as_str()).collect();
                anyhow::anyhow!(
                    "unknown hide profile '{wanted}', expected one of: {}",
                    names.join(", ")
                )
            })
    }

    /// `true` when this profile is strong enough to apply an entry whose
    /// minimum is `minimum`. [`Off`](Self::Off) never applies anything.
    pub const fn covers(self, minimum: Self) -> bool {
        (self as u8) >= (minimum as u8) && !matches!(self, Self::Off)
    }
}
