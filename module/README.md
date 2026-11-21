# NovaHide

One module that turns a SukiSU Nova device into a state a root checker accepts:
the SuSFS hide packs, the kernel hiding features, the bootloader properties and
the third-party hiding modules, all configured from one place and reported in
one place.

It bundles nobody else's binaries. It drives what is already on the device.

## What it aggregates

| Layer | What NovaHide does | Where it comes from |
|---|---|---|
| SuSFS path packs | Applies a profile (`light` … `aggressive`), device pack included | `ksud hide apply` |
| Kernel features | Owns and enables `selinux_hide`, `avc_spoof`, `mount_hide`, `kernel_umount` | `ksud feature set` |
| Mount hiding | Hides SUS mounts from every non-su process | `ksud susfs hide-sus-mnts-for-non-su-procs` |
| Kernel log | Turns SuSFS's own kernel logging off, so dmesg carries no hide records | `ksud susfs enable-log` |
| Self-hiding | Registers this module's directory and data dir, never mounts anything (`skip_mount`) | `ksud susfs add-sus-path` |
| Banking audit | Names the installed Vietnamese banking apps and what is still visible to them | `pm`, `settings`, `getenforce` |
| Map hiding | Hides Zygisk payloads from `/proc/<pid>/maps` | `ksud susfs add-sus-map` |
| Boot properties | Forces verified boot, warranty and debuggable properties to the stock values | `ksud resetprop` |
| Bootconfig | Serves a sanitised `/proc/bootconfig` | `ksud susfs set-cmdline-or-bootconfig` |
| TrickyStore | Adds the Play Integrity packages to `target.txt`, reports the keybox | its own `target.txt` |
| PlayIntegrityFix | Detects it and reports the fingerprint state, never rewrites it | detection only |
| Shamiko, Zygisk Next, LSPosed, HMA, SUSFS4KSU, APatch, Magisk | Reports state, conflicts and what each still needs | detection only |

## Requirements

- **SukiSU Nova** with the built-in hide packs: `ksud hide status` must work.
  The installer stops with a clear message if it does not.
- **A kernel with SuSFS** for the path, mount and map hiding. Without it the
  module still fixes properties and kernel features, and says so.
- **OnePlus Ace 5** (`giulia` / `giuliac`, models `PKG110` / `CPH2645`) gets its
  own pack: ColorOS state under `/data/oplus` and `/data/oppo` is hidden too,
  and the default profile is `aggressive`. Other devices start at `balanced`.

## Install

1. SukiSU Nova → Modules → Install from storage → pick the built zip,
   `novahide-v<version>.zip` (the name carries the version in `module.prop`).
2. Reboot. The first pass runs from `post-fs-data`, before zygote starts.
3. Or tap the module's action button to apply it immediately, without a reboot.

## What runs when

| Stage | What it does |
|---|---|
| `customize.sh` | Checks `ksud` and SuSFS, writes the config, claims the kernel features, prints what it found |
| `post-fs-data.sh` | Properties and kernel features first, then the hide pack — before any app process exists |
| `service.sh` | Paths, maps, bootconfig and the companion modules; writes the report |
| `boot-completed.sh` | One more pass once the system is settled, then the final report |
| `action.sh` | The manager action button and the WebUI: apply, status, JSON, log, purge, reset |
| `webroot/` | WebUI: verdicts, counts, companion modules, one-tap apply |

Everything is idempotent. Running the action twice does not duplicate a target
or re-add a path with a different meaning.

## Configuration

`/data/adb/novahide/config.conf`, plain `KEY=value`:

| Key | Default | Meaning |
|---|---|---|
| `PROFILE` | `auto` | `auto`, `off`, `light`, `balanced`, `aggressive`. `auto` follows the device pack. A profile picked from the action or the WebUI is written here, and to ksud's own store, so boot and the manager agree. |
| `MANAGE_FEATURES` | `1` | Own and enable the three kernel hiding features. |
| `HARDEN_PROPS` | `1` | Force the bootloader/verified-boot properties. |
| `CONFIGURE_COMPANIONS` | `1` | Write the settings companion modules expose. With `0`, a `target.txt` that `ksud hide apply` rewrites on its own is put back. |
| `HIDE_MAPS` | `1` | Hide Zygisk payloads from `/proc/<pid>/maps`. |
| `SPOOF_BOOTCONFIG` | `1` | Serve a sanitised `/proc/bootconfig`. |
| `STATUS_IN_DESCRIPTION` | `1` | Put the last run's summary into `module.prop`. |
| `SUSFS_KERNEL_LOG` | `0` | `1` turns SuSFS kernel logging back on for debugging. |
| `AUTO_DISABLE_CONFLICTS` | `0` | `1` also disables the conflicting module NovaHide names for a fixable conflict (see "Module conflicts"). Takes effect at the next boot. |

`PROFILE` controls the SuSFS side: the path packs, the extra self paths, mount
hiding, map hiding, the bootconfig and the kernel log. `off` registers nothing
new; hides an earlier boot or apply already registered stay until the next
reboot, because SuSFS has no command that removes a path, a map or mount
hiding. Properties, kernel features and companion modules have their own
switches, so `PROFILE=off` still sanitises the bootloader properties — that part
is what most detectors read first.

## Hiding the module itself

- The module mounts nothing (`skip_mount`), so there is no mount of its own to
  find in `/proc/mounts`.
- Its directory and its data directory are registered as SuSFS paths
  explicitly, not only through the catalog's `/data/adb/modules` row.
- Everything it writes (log, status, last apply, bootconfig copies, the
  `target.txt` snapshot) lives under `/data/adb/novahide`.
- `action.sh purge` deletes those traces and keeps the config, for when the
  device leaves your hands.
- `SUSFS_KERNEL_LOG=0` keeps the kernel log free of hide registrations.
- The Zygisk payloads are hidden from `/proc/<pid>/maps`. The runtime directory
  itself (`/data/system/nyazygisk`) is deliberately **not** hidden as a path:
  injected processes read their config from it, and hiding it would break the
  injection it is supposed to conceal.

## Module conflicts

Modules can leak root without any detector doing work: two Zygisk stacks
inject the same processes, two fingerprint modules overwrite each other's
props, a second hide pack undoes this one's registrations. Every apply and
every status run scans what is installed and reports what collides, in the
status report, the WebUI's "Module conflicts" panel, and the JSON.

| Conflict | Severity | What it means |
|---|---|---|
| Zygisk twice | high | Built-in Zygisk and Zygisk Next both inject; keep one. Fixable. |
| PIF twice | high | Two active fingerprint modules fight over the same props; keep one yourself. |
| SuSFS pack twice | medium | `susfs_manager` also applies a hide pack; the packs can disagree. Fixable. |
| second root | high | Magisk or APatch is installed as well; two root stacks fight over mounts. |
| Shamiko idle / HMA idle | info | The module needs a Zygisk to hook; with none running it does nothing. |

The scan is a report by default and changes nothing. With
`AUTO_DISABLE_CONFLICTS=1`, a write pass (boot or the Apply button) drops the
disable marker on the losing module of the two fixable conflicts — Zygisk Next
when the built-in stack runs, and `susfs_manager`. The marker takes effect at
the next boot, NovaHide never re-enables a module, and deleting the marker
brings the module back; which of the two Zygisk stacks to keep is always
yours, so re-check the WebUI after switching the flag on.

## Vietnamese banking apps

Root hiding applies to every non-su process, so a banking app is covered
whether or not this module knows its package name. What the list buys is a
readiness line that names the app and what it can still see:

```
banking
  installed        Vietcombank, MB Bank
  still visible    developer options on; manager app visible (com.sukisu.nova)
```

The built-in list covers Vietcombank, Techcombank, MB Bank, BIDV (Direct and
Smart OTP), VietinBank iPay, VPBank NEO and TPBank Mobile, each checked against
its Play Store listing. Add others with `EXTRA_BANKING_APPS` in the config.

The audit reports, and never changes, these vectors:

- developer options, USB debugging, wireless debugging, mock location
- SELinux permissive
- Frida artifacts under `/data/local/tmp`
- legacy Xposed
- the manager app itself, which PackageManager lists like any other app

The last one has a real fix: repackage the manager under a random name (the
manager's own build supports it), or hide it with HideMyApplist. Turning off
developer options and debugging is the user's call, and the module does not do
it behind their back.

## The verdict, honestly

The `applied` count is what the last apply registered, kept in
`/data/adb/novahide/last-apply`. `ksud hide status` reports the catalogue size
instead, which says nothing about whether the kernel accepted the hides, so a
status run without a recorded apply says `not verified` rather than guessing.

The report prints three readiness lines:

```
BASIC   ready
DEVICE  ready: PlayIntegrityFix supplies the fingerprint
STRONG  needs a keybox in TrickyStore
```

They describe **local readiness**: SuSFS is hiding paths, the properties read
locked, a fingerprint provider is installed, a keybox is present. They are not
a Play Integrity result. Google evaluates the verdict server-side from signals
no module can read, and rotates them. A device can be perfectly configured and
still fail an app's own extra checks.

- **BASIC** needs the device not to look modified: props, mounts, paths.
- **DEVICE** needs a fingerprint that Google still accepts — that is
  PlayIntegrityFix's job, and its fingerprint ages out like everyone else's.
- **STRONG** needs hardware-backed attestation, which in practice means a
  keybox in TrickyStore. No keybox is shipped here.

## OnePlus Ace 5 notes

- Codename `giulia` (global OnePlus 13R) or `giuliac` (China Ace 5). The module
  matches the codename, not the model, because a rebranded twin shares it.
- ColorOS keeps its own state under `/data/oplus` and `/data/oppo`; both are in
  the device pack at the `balanced` level, and the default profile is
  `aggressive`.
- The WildKernels OnePlus kernel for this device is built with SuSFS, so path,
  mount and map hiding are available without an extra userspace module.
- If `susfs_manager` (the auto-generated SuSFS module) is also installed, both
  modules apply a hide pack at boot. SuSFS only ever adds paths, so the
  strongest pack wins and cannot be lowered until a reboot. Keep one owner:
  either remove `susfs_manager` or set its profile to match.

## Troubleshooting

- `ksud hide status` fails → the manager/ksud predates the hide packs. Update
  SukiSU Nova, then flash again.
- Report says `susfs unavailable` → the running kernel has no SuSFS. Flash a
  kernel that has it; nothing else in this module can hide a path.
- `hide 0 applied` → the profile is `off`, or no catalog path exists on this
  device. Try `action.sh apply balanced`.
- `hide no apply recorded` → nothing has run since this boot. Tap the action
  button; the status view does not claim readiness from the catalogue alone.
- A banking app still fails → check the app's own list: it may look for the
  manager package, an unlocked bootloader in `/proc/bootconfig`, or a keybox it
  does not accept. `action.sh status` names what is missing, not what to install.
- Logs: `/data/adb/novahide/novahide.log` (rotated once at 256 KiB), last
  report in `/data/adb/novahide/status.txt`. `action.sh purge` removes both
  and the cached state, and keeps the config.

## Development

```sh
# build the flashable zip (validates metadata, sh -n, ShellCheck when present)
bash scripts/build-module.sh

# behavioural test: real scripts, a throwaway /data, stubbed ksud/getprop
sudo unshare -m sh module/tests/run-tests.sh
```

The test harness needs root and a mount namespace. It never touches the host's
`/data`: everything happens inside the namespace.

## Bắt đầu nhanh (tiếng Việt)

1. Tải file zip vừa build (`novahide-v<version>.zip`, tên mang theo phiên bản
   trong `module.prop`), mở SukiSU Nova → Modules → cài từ bộ nhớ.
2. Khởi động lại máy, hoặc bấm nút hành động của module để áp dụng ngay.
3. Mở WebUI của module để xem trạng thái: BASIC / DEVICE / STRONG, số đường dẫn
   đã ẩn, module ẩn root nào đang cài và còn thiếu gì.
4. Cần đổi mức ẩn: sửa `PROFILE` trong `/data/adb/novahide/config.conf` rồi bấm
   action, hoặc chọn profile ngay trong WebUI.

Lưu ý: STRONG integrity cần keybox trong TrickyStore; module không kèm keybox.
DEVICE integrity cần PlayIntegrityFix với fingerprint còn dùng được.

## Credits

- [SukiSU Nova](https://github.com/SukiSU-Nova/SukiSU-Nova) for `ksud`, the hide
  packs and the kernel features this module drives.
- [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) by simonpunk for the kernel
  side of path, mount and map hiding.
- The property list follows the Shamiko-derived script that ships with SukiSU's
  SuSFS module; the values are the ones a locked device reports.
- [TrickyStore](https://github.com/5ec1cff/TrickyStore),
  [PlayIntegrityFix](https://github.com/chiteroman/PlayIntegrityFix) and the
  other companion modules belong to their authors. This module configures and
  reports them; it does not redistribute them.
