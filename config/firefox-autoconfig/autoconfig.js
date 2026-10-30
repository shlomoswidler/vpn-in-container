// Loads single-window.cfg from the Firefox install directory (Firefox autoconfig).
// Mounted at /usr/lib/firefox/defaults/pref/autoconfig.js.
pref("general.config.filename", "single-window.cfg");
pref("general.config.obscure_value", 0);
// single-window.cfg needs Services, which the autoconfig sandbox does not provide.
pref("general.config.sandbox_enabled", false);
