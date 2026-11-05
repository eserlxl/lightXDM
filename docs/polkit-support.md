# Polkit Integration for lightXDM

This document explains how `lightXDM` integrates with Polkit to provide support for USB auto-mounting, power management, and session actions (like reboot, suspend, logout) without needing a display manager.

---

## ✨ What is Polkit?

Polkit (PolicyKit) is a framework for defining and handling **authorization** for privileged operations in desktop environments. When you try to:

* Mount a USB drive in Dolphin
* Reboot or suspend from the GUI
* Change power settings

...these actions are controlled by `polkit` rules.

Without a display manager nothing else starts the desktop's authentication agent, so lightXDM makes sure one runs; power actions are allowed by systemd's own policy in an active local session, so lightXDM installs no Polkit rule.

---

## 🔒 Power actions use systemd's defaults

Systemd's `login1` policy allows power-off, reboot, suspend and hibernate without a password in an active local session, including when other sessions are open. Remote or inactive sessions still need authentication. USB mounting uses `udisks2` defaults.

### The rule older versions installed

Older versions installed `/etc/polkit-1/rules.d/49-nopasswd.rules`. The newest versions redundantly granted the power actions to local active `wheel` users on seat0; the 2025 versions granted broader rights (the first one: every `udisks2`, `upower` and `login1` action to any `wheel` user, with no active-session check). `uninstall.sh` still removes an unmodified copy of any of them or restores the rule it replaced from `49-nopasswd.rules.lightxdm.bak`; `--no-polkit-rule` is accepted but has no effect.

> **Note:** The correct polkit agent is installed automatically for your desktop environment:
> - Plasma: polkit-kde-agent
> - LXQt: lxqt-policykit
> - XFCE and i3: polkit-gnome, started by `~/.xinitrc`
> - GNOME and Cinnamon: built into the shell; Budgie: budgie-polkit-dialog; LXDE: lxpolkit (lxsession); MATE: mate-polkit — each desktop starts its own, so lightXDM installs nothing extra
>
> Each of these was checked in a VM: an authorization request that needs a password opens the agent's dialog in a TTY1 session (`bash tests/qemu-arch.sh`).

---

## ⚠️ Optional: Less Secure (Full Access)

If you're the **only user** and want to allow all polkit actions for `wheel`, use this rule instead:

```js
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
```

> Warning: This allows any GUI app running as your user to elevate privileges automatically without a password.

---

## ⚙ Manual Polkit Agent Startup

For sessions that do not start a polkit agent automatically (such as i3 and XFCE, since Arch's `polkit-gnome` ships no XDG autostart entry), `~/.xinitrc` starts `polkit-gnome`:

```bash
if [ -x /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 ]; then
  /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 &
fi
```

Desktop environments such as KDE Plasma, GNOME, LXQt, LXDE, MATE, Cinnamon, and Budgie start their own polkit agent automatically and do not require a manual launch in `~/.xinitrc`.

---

## ✅ Verifying That It Works

* Plug in a USB drive — it should mount without password prompts.
* Click shutdown or suspend from the KDE application launcher — it should work instantly.
* Use `journalctl -b | grep polkit` to confirm rule loading.

---

## 🔧 Dependencies

Ensure the following packages are installed:

```
sudo pacman -S polkit udisks2 gvfs
# plus the GUI agent for your desktop:
sudo pacman -S polkit-kde-agent   # KDE Plasma
sudo pacman -S lxqt-policykit     # LXQt
sudo pacman -S polkit-gnome       # XFCE and i3 (other desktops bring their own agent)
```

These provide the Polkit backend and the authentication dialog for your desktop.

---

## 📄 Summary

| Feature        | Enabled By                          |
| -------------- | ----------------------------------- |
| USB automount  | `udisks2` defaults + polkit agent   |
| Reboot/Suspend/Hibernate | systemd's `login1` defaults |
| Brightness     | `UPower` defaults                   |
| GUI prompt     | polkit-kde-agent (Plasma), lxqt-policykit (LXQt), polkit-gnome (XFCE, i3), the desktop's own agent (GNOME, Cinnamon, Budgie, LXDE, MATE) |

Use the default secure rules for best safety, and only loosen them if you're fully aware of the consequences.

---

For more, see: [Polkit Arch Wiki](https://wiki.archlinux.org/title/Polkit) 
