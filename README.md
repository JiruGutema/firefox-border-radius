# firefox-border-radius

One command to set the corner radius of (almost) everything in Firefox: tabs,
toolbar buttons, the URL bar and its dropdown, menus, panels, the sidebar, and
internal pages like Settings and Add-ons.

This is the installable version of the guide
[How to Change the Border Radius of Everything in Firefox](https://jiru.is-a.dev/blogs/how-to-change-the-border-radius-of-everything-in-firefox-complete-guide).

## Install

```sh
git clone https://github.com/JiruGutema/firefox-border-radius.git
cd firefox-border-radius
./install.sh            # 4px everywhere
```

The script lists every Firefox install and profile it finds, and you pick
which profiles to apply it to:

```
Firefox installs
  Firefox (apt)          ~/.mozilla/firefox  (3 profiles)
  Firefox (flatpak)      ~/.var/app/org.mozilla.firefox/.mozilla/firefox  (1 profile)

Profiles
   1) default-release      Firefox (apt)        default, in use
   2) default-esr          Firefox (apt)        has other chrome/ files
   3) Profile 1            Firefox (apt)
   4) default-release      Firefox (flatpak)    default

Select profiles (e.g. 1 3, 2-4, a = all, q = quit) [a]:
```

Then quit Firefox completely and start it again.

| Look           | Command               |
| -------------- | --------------------- |
| Sharp corners  | `./install.sh -r 0`   |
| Subtle curves  | `./install.sh -r 4`   |
| Modern         | `./install.sh -r 8`   |
| Soft           | `./install.sh -r 12`  |

Re-run with a different `-r` at any time.

## Supported installs

| Install                          | Profiles in                                        |
| -------------------------------- | -------------------------------------------------- |
| apt / dnf / pacman / tarball     | `~/.mozilla/firefox`, `~/.config/mozilla/firefox`  |
| Snap                             | `~/snap/firefox/common/.mozilla/firefox`           |
| Flatpak                          | `~/.var/app/org.mozilla.firefox/...`               |
| macOS                            | `~/Library/Application Support/Firefox`            |
| LibreWolf, Floorp, Zen, Waterfox | their own folders (native and Flatpak)             |

Each profile is labelled with the install it belongs to, so you can tell an
apt profile from a Snap one. Profiles left behind by an uninstalled package
are still listed and marked `app not found`. Windows isn't supported by
`install.sh`; copy the files in `src/` by hand and replace `@RADIUS@`.

## What it does

For each profile you select:

1. **Replaces `chrome/`.** If the folder holds anything besides files this
   script wrote (an old theme, a copy-pasted `userChrome.css`, ...), it is moved
   to `~/.local/share/firefox-border-radius/backups/<profile>-<time>/`. The new
   `chrome/` contains only `userChrome.css` and `userContent.css`.
2. **Enables custom stylesheets** by adding
   `toolkit.legacyUserProfileCustomizations.stylesheets` to the profile's
   `user.js`, so you don't need `about:config`. The rest of `user.js` is kept.

## Options

```
-r, --radius VALUE   Corner radius, e.g. 0, 4, 8px (default: 4px)
-a, --all            Apply to every profile found, without the menu
-p, --profile DIR    Apply to this profile directory (repeatable, skips the menu)
-l, --list           List Firefox installs and profiles, then exit
-u, --uninstall      Remove firefox-border-radius from the profiles you choose
    --no-content     Leave about: pages alone (don't install userContent.css)
-y, --yes            Don't ask for confirmation
```

Your profile folder is listed in `about:support` under **Profile Folder**.

## Uninstall

```sh
./install.sh --uninstall
```

This removes the two CSS files and the `user.js` line it added. If an older
`chrome/` folder was backed up, the script prints where it is so you can move
it back.

## How it works

Modern Firefox draws nearly every rounded corner from a small set of design
tokens (`--border-radius-small`, `--button-border-radius`,
`--tab-border-radius`, `--panel-border-radius`, ...). Overriding those tokens
covers far more of the UI than targeting individual selectors, and it keeps
working when Mozilla renames elements. `--border-radius-circle` is left alone,
so things meant to be round (avatars, badges, toggle knobs) stay round.

Edit `src/userChrome.css` or `src/userContent.css` to add your own rules, then
re-run `./install.sh`. `@RADIUS@` is replaced with the chosen value.

## License

[MIT](LICENSE)
