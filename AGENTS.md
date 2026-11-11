# Working on ios-galaxy

- Read `NOTES.md` before starting: target hardware facts, the decisions made
  with the user, what is verified and what is not, and the next action.
  `docs/sweet-redmi-NOTES.md` is the history of the original Redmi Note 10
  Pro port (patches 0001-0081); it explains most of the generic iOS work.
- Target: Samsung Galaxy J7 Neo SM-J701M (Exynos 7870). The kernel machine
  config keeps the name SWEET; patches 0082+ retarget it. Make new kernel
  changes as new numbered patches on top (contiguous numbering:
  tools/validate-repo.py checks it); regenerate them from a patched tree
  and verify that the whole series applies to xnu-8796.141.3.
- The user works on macOS (Apple Silicon), not Linux. Every host step must
  work there (Homebrew tools); Linux support is optional.
- Update `NOTES.md` after each milestone. Record commits, CI run IDs, exact
  build/boot results and unfinished work. Distinguish observations from guesses.
- The phone is flashed from TWRP over adb (tools/j7-flash.sh): BOOT and the
  start of USERDATA only. Keep the partition backups. Confirm each
  destructive step with the user before running it.
- Keep device dumps, serial numbers and downloaded Apple artifacts out of git.
