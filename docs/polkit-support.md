# Polkit Integration for lightXDM

This document explains how `lightXDM` integrates with Polkit to provide support for USB auto-mounting, power management, and session actions (like reboot, suspend, logout) without needing a display manager.

---

## ✨ What is Polkit?

Polkit (PolicyKit) is a framework for defining and handling **authorization** for privileged operations in desktop environments. When you try to:

* Mount a USB drive in Dolphin
* Reboot or suspend from the GUI
* Change power settings

...these actions are controlled by `polkit` rules.

In systems with no display manager (like SDDM or GDM), some polkit agents and privileges may not work unless explicitly enabled. `lightXDM` solves this by manually starting a polkit agent and installing scoped rules.

---

## 🔒 The Default Polkit Rule (Hybrid: Secure & Usable)

By default, `lightXDM` now installs a hybrid rule at:

```
/etc/polkit-1/rules.d/49-nopasswd.rules
```

**Content:**

```js
// Allow local, active wheel users on seat0 to shutdown/reboot/suspend without password
polkit.addRule(function(action, subject) {
  if (
    subject.isInGroup("wheel") &&
    subject.local &&
    subject.active &&
    subject.seat === "seat0"
  ) {
    // Allow shutdown, reboot, suspend without password
    if (
      action.id === "org.freedesktop.login1.power-off" ||
      action.id === "org.freedesktop.login1.reboot" ||
      action.id === "org.freedesktop.login1.suspend"
    ) {
      return polkit.Result.YES;
    }
  }
});
```

### ✅ What this allows:

* **Shutdown, reboot, suspend** from the GUI for local, active users in the `wheel` group (no password required)
* **Mounting removable drives** (`udisks2` defaults) and **power management** (`UPower` defaults) for active local users without overriding upstream policies

### ❌ What it doesn't allow:

* Arbitrary admin-level system changes
* Package installations via polkit
* Actions from unknown services
* Remote or inactive users to shutdown/reboot/suspend

This hybrid rule balances usability and security: trusted local users can power off or reboot without a password, but other privileged actions still require authentication.

> **Note:** The correct polkit agent is installed automatically for your desktop environment:
> - KDE Plasma: polkit-kde-agent
> - LXQt: lxqt-policykit
> - All others: polkit-gnome

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
sudo pacman -S polkit udisks2 kde-cli-tools kio-extras gvfs
```

These provide the necessary backend support for KDE to interact with Polkit.

---

## 📄 Summary

| Feature        | Enabled By                          |
| -------------- | ----------------------------------- |
| USB automount  | `udisks2` defaults + polkit agent   |
| Reboot/Suspend | `login1` rule                       |
| Brightness     | `UPower` defaults                   |
| GUI prompt     | `polkit-kde-authentication-agent-1` |

Use the default secure rules for best safety, and only loosen them if you're fully aware of the consequences.

---

For more, see: [Polkit Arch Wiki](https://wiki.archlinux.org/title/Polkit) 
