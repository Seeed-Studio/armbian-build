# Changelog

## 2026-05-25

- armbian: bypass proxy for Seeed repo fetches and fix extension hook ordering
- armbian: normalize SDCARD quoting style in board configs
- armbian: move Seeed extension enable_extension back to board config scope
- armbian: fix X11 GPU selection and enable Wayland for Mali EGL
- armbian: restore Mesa libgbm and lower DP default resolution
- armbian: add gh CLI fallback for aic8800 release version detection
- armbian: overhaul dp-dsi-resolve for triple-output hotplug stability
- armbian: limit DP to 50Hz to fix boot FIFO overflow
- armbian: fix GDM X11 for Bookworm and improve multi-output layout
- armbian: remove dp-dsi-resolve script and simplify GDM config
