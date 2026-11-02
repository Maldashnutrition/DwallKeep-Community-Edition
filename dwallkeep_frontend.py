#!/usr/bin/env python3
# DwallKeep — VPN + Tor chain manager
# Copyright (C) 2025 Siyavuyisa Ntengo
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
# =============================================================================
import customtkinter as ctk
import tkinter as tk
from tkinter import messagebox, filedialog, ttk
import subprocess
import threading
import os
import queue
import time
import json
from PIL import Image

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT_PATH = os.path.join(SCRIPT_DIR, "dwallkeep_backend.sh")
LOGO_PATH = os.path.join(SCRIPT_DIR, "logo.png")
CONTAINER_NAME = "mc"

APP_CONFIG_DIR = os.path.expanduser("~/.config/dwallkeep")
APP_CONFIG_FILE = os.path.join(APP_CONFIG_DIR, "config.json")

BG_COLOR       = ("#f3f4f6", "#050505")
FRAME_COLOR    = ("#ffffff", "#111111")
ACCENT_BLUE    = ("#1f5fa8", "#3b7bb8")
ACCENT_HOVER   = ("#17477e", "#2e6396")
TEXT_COLOR     = ("#111111", "#e0e0e0")
SUBTEXT_COLOR  = ("#555555", "#888888")
CONSOLE_BG     = ("#ffffff", "#000000")
CONSOLE_TEXT   = ("#1a1a1a", "#cccccc")
BORDER_SUBTLE  = ("#d0d0d0", "#222222")
BANNER_BG      = ("#fff8e6", "#2a2210")
BANNER_BORDER  = ("#e0a020", "#f0ad4e")
TOAST_BG       = ("#ffffff", "#0f0f0f")
TOAST_TEXT     = ("#111111", "#ffffff")
TOAST_SUBTEXT  = ("#555555", "#cccccc")

RED    = "#d9534f"
GREEN  = "#5cb85c"
YELLOW = "#f0ad4e"

USAGE_NOTICE = (
    "THIS TOOL USES VPNBOOK'S FREE SERVERS.\n\n"
    "VPNBook's policy: \"This free VPN service is for personal use only.\"\n"
    "They log every connection IP and ban abusers:\n"
    "  \"If you abuse the system, your IP will be banned.\"\n\n"
    "TO AVOID BEING BLOCKED:\n"
    "  • Keep 15+ minutes between chain starts (enforced automatically).\n"
    "  • Override is limited to 3 uses per 25 minutes.\n"
    "  • Do not automate reconnection or run this on many machines at once.\n"
    "  • Use the tool like a human: connect once, browse, disconnect.\n\n"
    "WHEN YOU STOP A CHAIN:\n"
    "  • The container is destroyed.\n"
    "  • Files saved inside the container are permanently lost.\n"
    "  • Files copied to the host via File Explorer are safe.\n"
    "  • Downloads inside Firefox land in /root/Downloads in the\n"
    "    container and WILL BE LOST. Copy them to the host first.\n\n"
    "By clicking \"I Understand\" you accept personal responsibility for\n"
    "how you use this tool."
)


def load_app_config():
    try:
        with open(APP_CONFIG_FILE) as f:
            return json.load(f)
    except Exception:
        return {}

def save_app_config(cfg):
    try:
        os.makedirs(APP_CONFIG_DIR, exist_ok=True)
        with open(APP_CONFIG_FILE, "w") as f:
            json.dump(cfg, f, indent=2)
    except Exception:
        pass


class Toast(ctk.CTkToplevel):
    """Sliding bottom-right toast. Auto-dismisses after `duration` ms.

    Runs entirely on the Tk main thread. Every scheduled callback and every
    geometry() call is guarded behind self._alive so a destroyed widget
    never raises `bad window path name`.

    A hard fail-safe (`_hard_kill_job`) destroys the window unconditionally
    at `duration + 4000` ms, so even if the normal close path bails for any
    reason (geometry exception during slide, callback cancelled, Tk
    re-entrancy weirdness), the toast cannot linger on screen forever.

    Tear-down uses `_safe_unmap_and_destroy`: move off-screen → flush →
    withdraw → force parent repaint → delayed destroy. This is required
    because overrideredirect Toplevels are not managed by the WM, so on
    X11 compositors (XFCE/picom, GNOME/mutter, KDE/kwin) the vacated
    region would otherwise not be repainted, leaving a stale black box.
    """
    _active = []
    _MAX = 3

    def __init__(self, master, title, message, kind="info", duration=7000):
        super().__init__(master)
        self._alive = True
        self._closing = False
        self._dismiss_job = None
        self._hard_kill_job = None

        self.overrideredirect(True)
        try:
            self.attributes("-topmost", True)
        except Exception:
            pass
        self.configure(fg_color=TOAST_BG)

        accent = {
            "info":    ACCENT_BLUE,
            "success": ("#3d8b40", GREEN),
            "warning": ("#a07817", YELLOW),
            "error":   ("#a02c2c", RED),
        }.get(kind, ACCENT_BLUE)

        outer = ctk.CTkFrame(self, fg_color=accent, corner_radius=10)
        outer.pack(fill="both", expand=True)
        inner = ctk.CTkFrame(outer, fg_color=TOAST_BG, corner_radius=8)
        inner.pack(fill="both", expand=True, padx=2, pady=2)

        ctk.CTkLabel(inner, text=title,
                     font=ctk.CTkFont(size=13, weight="bold"),
                     text_color=TOAST_TEXT, anchor="w",
                     ).pack(fill="x", padx=15, pady=(10, 2))
        ctk.CTkLabel(inner, text=message,
                     font=ctk.CTkFont(size=11),
                     text_color=TOAST_SUBTEXT, anchor="w",
                     wraplength=340, justify="left",
                     ).pack(fill="x", padx=15, pady=(0, 10))
        for w in (self, outer, inner):
            w.bind("<Button-1>", lambda e: self._close())

        self.update_idletasks()
        w = 380
        try:
            h = max(80, self.winfo_reqheight())
            sh = self.winfo_screenheight()
            sw = self.winfo_screenwidth()
        except Exception:
            sh, sw, h = 800, 1024, 80

        Toast._active = [t for t in Toast._active
                         if getattr(t, "_alive", False)]
        if len(Toast._active) >= Toast._MAX:
            try:
                Toast._active[0]._close()
            except Exception:
                pass
        slot = len(Toast._active)

        self._x = sw - w - 20
        self._w = w
        self._h = h
        self._target_y = sh - 60 - h - (slot * (h + 10))
        try:
            self.geometry(f"{w}x{h}+{self._x}+{sh + 20}")
        except Exception:
            pass
        Toast._active.append(self)

        self._anim_in(0)
        try:
            self._dismiss_job = self.after(duration, self._close)
        except Exception:
            self._dismiss_job = None
        try:
            self._hard_kill_job = self.after(
                duration + 4000, self._force_destroy)
        except Exception:
            self._hard_kill_job = None

    def _safe_after(self, ms, fn):
        if not self._alive:
            return
        try:
            self.after(ms, fn)
        except Exception:
            self._alive = False

    def _anim_in(self, step):
        if not self._alive or self._closing:
            return
        if step > 18:
            return
        p = 1 - (1 - step / 18) ** 2
        try:
            sh = self.winfo_screenheight()
            y = int((sh + 20) + (self._target_y - sh - 20) * p)
            self.geometry(f"+{self._x}+{y}")
        except Exception:
            self._alive = False
            return
        self._safe_after(16, lambda: self._anim_in(step + 1))

    def _close(self):
        if not self._alive or self._closing:
            return
        self._closing = True
        if self._dismiss_job is not None:
            try:
                self.after_cancel(self._dismiss_job)
            except Exception:
                pass
            self._dismiss_job = None
        try:
            Toast._active.remove(self)
        except Exception:
            pass
        self._anim_out(0)

    def _anim_out(self, step):
        if not self._alive:
            return
        if step > 14:
            self._destroy_self()
            return
        p = (step / 14) ** 2
        try:
            sh = self.winfo_screenheight()
            y = int(self._target_y + (sh - self._target_y + 20) * p)
            self.geometry(f"+{self._x}+{y}")
        except Exception:
            self._destroy_self()
            return
        self._safe_after(16, lambda: self._anim_out(step + 1))

    def _safe_unmap_and_destroy(self):
        for jname in ("_dismiss_job", "_hard_kill_job"):
            job = getattr(self, jname, None)
            if job is not None:
                try:
                    self.after_cancel(job)
                except Exception:
                    pass
                setattr(self, jname, None)
        try:
            Toast._active.remove(self)
        except Exception:
            pass
        self._alive = False
        try:
            sh = self.winfo_screenheight()
            self.geometry(f"+{self._x}+{sh + 200}")
            self.update_idletasks()
            self.update()
        except Exception:
            pass
        try:
            self.withdraw()
            self.update_idletasks()
        except Exception:
            pass
        try:
            if self.master is not None and self.master.winfo_exists():
                self.master.update_idletasks()
                self.master.update()
        except Exception:
            pass
        def _really_destroy():
            try:
                self.destroy()
            except Exception:
                pass

        try:
            self.after(80, _really_destroy)
        except Exception:
            try:
                self.destroy()
            except Exception:
                pass

    def _destroy_self(self):
        self._safe_unmap_and_destroy()

    def _force_destroy(self):
        self._safe_unmap_and_destroy()


class DwallKeepApp(ctk.CTk):
    def __init__(self):
        super().__init__()
        self.title("DwallKeep")
        self.geometry("1020x760")
        self.configure(fg_color=BG_COLOR)
        self.resizable(True, True)
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        self.process = None
        self.log_queue = queue.Queue()
        self.is_running = False
        self.is_starting = False
        self.is_stopping = False
        self.container_pid = None
        self.exit_ip = "Unknown"
        self.launching = set()
        self.chain_mode = "unknown"
        self._warned_2hop = False
        self._pulse_phase = 0
        self._banner_expanded = tk.BooleanVar(value=False)

        self.app_config = load_app_config()
        self.use_custom_var = tk.BooleanVar(value=False)
        self.custom_entry_var = tk.StringVar(
            value=self.app_config.get("custom_entry", ""))
        self.custom_exit_var = tk.StringVar(
            value=self.app_config.get("custom_exit", ""))
        self.custom_auth_var = tk.StringVar(
            value=self.app_config.get("custom_auth", ""))

        try:
            self.attributes("-alpha", 0.0)
        except Exception:
            pass

        self.build_ui()
        self.after(100, self.poll_logs)
        self.check_status_thread()
        self.after(40, lambda: self._fade_in(0))
        self.after(200, self._maybe_show_usage_dialog)
    def _fade_in(self, step):
        total = 16
        if step > total:
            try:
                self.attributes("-alpha", 1.0)
            except Exception:
                pass
            return
        try:
            self.attributes("-alpha", step / total)
        except Exception:
            return
        self.after(20, lambda: self._fade_in(step + 1))
    def notify(self, title, message, kind="info", duration=7000, system=True):
        def _show():
            try:
                Toast(self, title, message, kind=kind, duration=duration)
            except Exception as e:
                self.log(f"[Notify] in-app failed: {e}\n")
        try:
            self.after(0, _show)
        except Exception as e:
            self.log(f"[Notify] scheduling failed: {e}\n")

        if system:
            try:
                urgency = {"error": "normal", "warning": "normal",
                           "info": "low", "success": "normal"}.get(
                               kind, "normal")
                subprocess.Popen(
                    ["notify-send", "-a", "DwallKeep", "-u", urgency,
                     "-t", str(duration), "-i", "security-high",
                     title, message],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
    def build_ui(self):
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(0, weight=1)

        self.tabview = ctk.CTkTabview(
            self, fg_color=BG_COLOR,
            segmented_button_fg_color=FRAME_COLOR,
            segmented_button_selected_color=ACCENT_BLUE,
            segmented_button_selected_hover_color=ACCENT_HOVER,
            text_color=TEXT_COLOR,
        )
        self.tabview.pack(fill="both", expand=True, padx=10, pady=10)

        self.tab_login = self.tabview.add("Login & Connection")
        self.tab_custom = self.tabview.add("Custom OVPN")
        self.tab_desktop = self.tabview.add("Desktop")

        self.build_login_tab()
        self.build_custom_tab()
        self.build_desktop_tab()

        self.tabview._segmented_button._buttons_dict["Desktop"].configure(state="disabled")

    def _build_usage_banner(self):
        box = ctk.CTkFrame(self.tab_login, fg_color=BANNER_BG, corner_radius=8,
                           border_width=1, border_color=BANNER_BORDER)
        box.grid(row=0, column=0, sticky="ew", padx=20, pady=(10, 6))

        header = ctk.CTkFrame(box, fg_color="transparent")
        header.pack(fill="x", padx=10, pady=(8, 4))
        ctk.CTkLabel(header, text="⚠  Responsible Use Required",
                     font=ctk.CTkFont(size=12, weight="bold"),
                     text_color=("#a02c2c", "#f0ad4e")).pack(side="left")

        self._banner_toggle = ctk.CTkButton(
            header, text="Show details ▼", width=110, height=22,
            font=ctk.CTkFont(size=10),
            fg_color="transparent", hover_color=BORDER_SUBTLE,
            text_color=SUBTEXT_COLOR, command=self._toggle_banner)
        self._banner_toggle.pack(side="right")

        self._banner_content = ctk.CTkFrame(box, fg_color="transparent")
        ctk.CTkLabel(self._banner_content, text=USAGE_NOTICE,
                     font=ctk.CTkFont(size=11), text_color=TEXT_COLOR,
                     justify="left", anchor="w", wraplength=900,
                     ).pack(fill="x", padx=15, pady=(4, 10))

    def _toggle_banner(self):
        if self._banner_expanded.get():
            self._banner_content.pack_forget()
            self._banner_toggle.configure(text="Show details ▼")
            self._banner_expanded.set(False)
        else:
            self._banner_content.pack(fill="x")
            self._banner_toggle.configure(text="Hide details ▲")
            self._banner_expanded.set(True)

    def build_login_tab(self):
        self.tab_login.grid_columnconfigure(0, weight=1)
        self.tab_login.grid_rowconfigure(4, weight=1)

        self._build_usage_banner()
        header = ctk.CTkFrame(self.tab_login, fg_color="transparent")
        header.grid(row=1, column=0, pady=(2, 6), sticky="ew")

        ctk.CTkFrame(header, fg_color="transparent", width=40).pack(side="left")

        center = ctk.CTkFrame(header, fg_color="transparent")
        center.pack(side="left", expand=True)

        if os.path.exists(LOGO_PATH):
            img = ctk.CTkImage(light_image=Image.open(LOGO_PATH),
                               dark_image=Image.open(LOGO_PATH), size=(70, 70))
            ctk.CTkLabel(center, image=img, text="").pack()
        else:
            ctk.CTkLabel(center, text="D",
                         font=ctk.CTkFont(size=44, weight="bold"),
                         text_color=ACCENT_BLUE).pack()

        ctk.CTkLabel(center, text="DWALLKEEP",
                     font=ctk.CTkFont(size=26, weight="bold"),
                     text_color=ACCENT_BLUE).pack(pady=(2, 0))
        ctk.CTkLabel(center, text="YOUR SPACE. YOUR LIFE.",
                     font=ctk.CTkFont(size=11),
                     text_color=SUBTEXT_COLOR).pack()

        self.theme_btn = ctk.CTkButton(
            header, text="☀", width=36, height=36,
            fg_color=FRAME_COLOR, hover_color=ACCENT_HOVER,
            text_color=TEXT_COLOR, corner_radius=8,
            command=self.toggle_theme)
        self.theme_btn.pack(side="right", padx=10)
        ctrl = ctk.CTkFrame(self.tab_login, fg_color=FRAME_COLOR, corner_radius=10)
        ctrl.grid(row=2, column=0, pady=6, padx=20, sticky="ew")

        self.status_label = ctk.CTkLabel(ctrl, text="● OFFLINE",
                                         font=ctk.CTkFont(size=14, weight="bold"),
                                         text_color=RED)
        self.status_label.pack(side="left", padx=20, pady=15)

        self.pass_entry = ctk.CTkEntry(ctrl, placeholder_text="VPNBook Password",
                                       width=200, show="*")
        self.pass_entry.pack(side="left", padx=10, expand=True)

        self.btn_stop = ctk.CTkButton(
            ctrl, text="Stop", fg_color="transparent", border_width=1,
            border_color=ACCENT_BLUE, text_color=ACCENT_BLUE,
            hover_color=BORDER_SUBTLE, width=80,
            command=self.stop_chain, state="disabled")
        self.btn_stop.pack(side="right", padx=10)

        self.btn_start = ctk.CTkButton(
            ctrl, text="Start Chain", fg_color=ACCENT_BLUE,
            hover_color=ACCENT_HOVER, width=110, command=self.start_chain)
        self.btn_start.pack(side="right", padx=5)
        opts = ctk.CTkFrame(self.tab_login, fg_color="transparent")
        opts.grid(row=3, column=0, sticky="ew", padx=25, pady=(0, 4))

        self.custom_checkbox = ctk.CTkCheckBox(
            opts, text="Use Custom OVPN (configure in 'Custom OVPN' tab)",
            variable=self.use_custom_var, command=self._on_custom_toggle,
            font=ctk.CTkFont(size=11),
            text_color=SUBTEXT_COLOR)
        self.custom_checkbox.pack(side="left")
        console_frame = ctk.CTkFrame(self.tab_login, fg_color=FRAME_COLOR, corner_radius=10)
        console_frame.grid(row=4, column=0, pady=(0, 20), padx=20, sticky="nsew")
        console_frame.grid_columnconfigure(0, weight=1)
        console_frame.grid_rowconfigure(1, weight=1)

        ctk.CTkLabel(console_frame, text=" System Output ",
                     font=ctk.CTkFont(size=11),
                     text_color=SUBTEXT_COLOR,
                     ).grid(row=0, column=0, sticky="w", padx=10, pady=(5, 0))
        self.console = ctk.CTkTextbox(console_frame, fg_color=CONSOLE_BG,
                                      text_color=CONSOLE_TEXT,
                                      font=("Courier New", 12), wrap="word")
        self.console.grid(row=1, column=0, padx=10, pady=(0, 10), sticky="nsew")
        self.console.insert("0.0", "System idle. Click 'Start Chain' to begin.\n")
        self.console.configure(state="disabled")

    def build_custom_tab(self):
        self.tab_custom.grid_columnconfigure(0, weight=1)

        header = ctk.CTkFrame(self.tab_custom, fg_color=FRAME_COLOR, corner_radius=10)
        header.grid(row=0, column=0, sticky="ew", padx=20, pady=(20, 10))
        ctk.CTkLabel(header, text="Use your own OpenVPN configs",
                     font=ctk.CTkFont(size=16, weight="bold"),
                     text_color=ACCENT_BLUE).pack(pady=(10, 4))
        ctk.CTkLabel(header,
                     text="Select .ovpn files for entry and exit hops. "
                          "Auth file is optional (needed only for user/pass configs). "
                          "Custom OVPN bypasses VPNBook cooldowns and override limits.",
                     font=ctk.CTkFont(size=11), text_color=SUBTEXT_COLOR,
                     wraplength=880, justify="center").pack(padx=20, pady=(0, 12))

        for row_idx, (label, var, kind) in enumerate([
            ("Entry .ovpn", self.custom_entry_var, "ovpn"),
            ("Exit .ovpn",  self.custom_exit_var,  "ovpn"),
            ("Auth (opt)",  self.custom_auth_var,  "auth"),
        ]):
            row = ctk.CTkFrame(self.tab_custom, fg_color=FRAME_COLOR, corner_radius=10)
            row.grid(row=1 + row_idx, column=0, sticky="ew", padx=20, pady=4)
            ctk.CTkLabel(row, text=label, width=110, anchor="w",
                         text_color=TEXT_COLOR).pack(side="left", padx=15, pady=10)
            ctk.CTkEntry(row, textvariable=var,
                         fg_color=BG_COLOR, text_color=TEXT_COLOR,
                         ).pack(side="left", fill="x", expand=True, padx=5, pady=10)
            ctk.CTkButton(row, text="Browse", width=80,
                          fg_color=ACCENT_BLUE, hover_color=ACCENT_HOVER,
                          command=lambda v=var, k=kind: self._browse_file(v, k),
                          ).pack(side="right", padx=15, pady=10)

        info = ctk.CTkFrame(self.tab_custom, fg_color=FRAME_COLOR, corner_radius=10)
        info.grid(row=4, column=0, sticky="ew", padx=20, pady=(15, 5))
        ctk.CTkLabel(info,
                     text="HOW TO ACTIVATE:\n"
                          "  1. Fill in Entry and Exit .ovpn files above.\n"
                          "  2. Go to 'Login & Connection' tab.\n"
                          "  3. Check 'Use Custom OVPN' and click Start Chain.\n\n"
                          "NOTES:\n"
                          "  • If the exit .ovpn fails to connect, the chain falls "
                          "back to 2-hop (entry + Tor, no exit).\n"
                          "  • Auth file format: username on line 1, password on "
                          "line 2. Leave blank for certificate-only configs.\n"
                          "  • Custom OVPN is not subject to VPNBook cooldown or "
                          "override limits — but do not abuse whichever provider "
                          "you point this at.",
                     font=ctk.CTkFont(size=12), text_color=SUBTEXT_COLOR,
                     justify="left", anchor="w",
                     ).pack(padx=15, pady=15, fill="x")

        ctk.CTkButton(self.tab_custom, text="Save Configuration",
                      fg_color=ACCENT_BLUE, hover_color=ACCENT_HOVER,
                      width=200, height=34,
                      command=self._save_custom_config,
                      ).grid(row=5, column=0, pady=20)

    def build_desktop_tab(self):
        self.tab_desktop.grid_columnconfigure(0, weight=1)
        self.tab_desktop.grid_rowconfigure(1, weight=1)

        topbar = ctk.CTkFrame(self.tab_desktop, fg_color=FRAME_COLOR, corner_radius=10)
        topbar.grid(row=0, column=0, sticky="ew", padx=10, pady=5)
        ctk.CTkLabel(topbar, text="DwallKeep Desktop",
                     font=ctk.CTkFont(size=16, weight="bold"),
                     text_color=ACCENT_BLUE).pack(side="left", padx=15)
        self.ip_label = ctk.CTkLabel(topbar, text="Exit IP: Fetching...",
                                     font=ctk.CTkFont(size=13),
                                     text_color=TEXT_COLOR)
        self.ip_label.pack(side="right", padx=15)

        grid = ctk.CTkFrame(self.tab_desktop, fg_color=FRAME_COLOR, corner_radius=10)
        grid.grid(row=1, column=0, sticky="nsew", padx=10, pady=(5, 10))
        grid.grid_columnconfigure((0, 1), weight=1)
        grid.grid_rowconfigure((0, 1), weight=1)

        for i, (name, cmd) in enumerate([
            ("Firefox",       self.launch_firefox),
            ("Terminal",      self.launch_terminal),
            ("Notepad",       self.launch_notepad),
            ("File Explorer", self.launch_file_explorer),
        ]):
            ctk.CTkButton(grid, text=name, width=140, height=120,
                          fg_color=BG_COLOR, hover_color=ACCENT_HOVER,
                          text_color=TEXT_COLOR, corner_radius=15,
                          font=ctk.CTkFont(size=14, weight="bold"),
                          command=cmd,
                          ).grid(row=i // 2, column=i % 2, padx=20, pady=20)

        self.desktop_status = ctk.CTkLabel(
            grid, text="Connected. All apps route through your chain.",
            text_color=GREEN)
        self.desktop_status.grid(row=2, column=0, columnspan=2, pady=10)
    def toggle_theme(self):
        if ctk.get_appearance_mode().lower() == "dark":
            ctk.set_appearance_mode("light")
            self.theme_btn.configure(text="🌙")
        else:
            ctk.set_appearance_mode("dark")
            self.theme_btn.configure(text="☀")
    def _maybe_show_usage_dialog(self):
        if self.app_config.get("usage_acknowledged"):
            return
        if not self._show_usage_dialog():
            self.destroy()

    def _show_usage_dialog(self):
        dlg = ctk.CTkToplevel(self)
        dlg.title("Important: Read Before Use")
        dlg.geometry("640x560")
        dlg.configure(fg_color=BG_COLOR)
        dlg.transient(self)
        dlg.grab_set()

        ctk.CTkLabel(dlg, text="⚠  Before You Continue",
                     font=ctk.CTkFont(size=20, weight="bold"),
                     text_color=("#a02c2c", "#f0ad4e")).pack(pady=(20, 10))

        scroll = ctk.CTkScrollableFrame(dlg, fg_color=FRAME_COLOR,
                                        corner_radius=10, width=580, height=380)
        scroll.pack(padx=20, pady=10, fill="both", expand=True)
        ctk.CTkLabel(scroll, text=USAGE_NOTICE,
                     font=ctk.CTkFont(size=12), text_color=TEXT_COLOR,
                     justify="left", anchor="w", wraplength=530,
                     ).pack(padx=15, pady=15, fill="x")

        row = ctk.CTkFrame(dlg, fg_color="transparent")
        row.pack(fill="x", padx=20, pady=(5, 20))

        def accept():
            self.app_config["usage_acknowledged"] = True
            save_app_config(self.app_config)
            dlg.destroy()

        def decline():
            dlg.destroy()

        ctk.CTkButton(row, text="I Understand — Proceed",
                      fg_color=ACCENT_BLUE, hover_color=ACCENT_HOVER,
                      width=220, command=accept,
                      ).pack(side="right", padx=5)
        ctk.CTkButton(row, text="Cancel",
                      fg_color="transparent", border_width=1,
                      border_color=ACCENT_BLUE, text_color=ACCENT_BLUE,
                      hover_color=BORDER_SUBTLE, width=100,
                      command=decline,
                      ).pack(side="right", padx=5)

        self.wait_window(dlg)
        return self.app_config.get("usage_acknowledged", False)
    def _on_custom_toggle(self):
        if self.use_custom_var.get():
            self.pass_entry.configure(state="disabled",
                                      placeholder_text="(using custom OVPN)")
        else:
            self.pass_entry.configure(state="normal",
                                      placeholder_text="VPNBook Password")

    def _browse_file(self, var, kind):
        if kind == "ovpn":
            path = filedialog.askopenfilename(
                title="Select OpenVPN config",
                filetypes=[("OpenVPN configs", "*.ovpn"),
                           ("All files", "*.*")])
        else:
            path = filedialog.askopenfilename(
                title="Select auth file",
                filetypes=[("Auth file", "*.txt"),
                           ("All files", "*.*")])
        if path:
            var.set(path)

    def _save_custom_config(self):
        self.app_config["custom_entry"] = self.custom_entry_var.get().strip()
        self.app_config["custom_exit"] = self.custom_exit_var.get().strip()
        self.app_config["custom_auth"] = self.custom_auth_var.get().strip()
        save_app_config(self.app_config)
        self.notify("Saved", "Custom OVPN configuration saved.", kind="success")
    def log(self, text):
        self.log_queue.put(text)

    def poll_logs(self):
        try:
            while True:
                line = self.log_queue.get_nowait()
                self.console.configure(state="normal")
                self.console.insert("end", line)
                self.console.see("end")
                self.console.configure(state="disabled")
        except queue.Empty:
            pass
        self.after(100, self.poll_logs)

    def _start_pulse(self):
        self._pulse_phase = 0
        self._pulse_tick()

    def _pulse_tick(self):
        if not self.is_starting and not self.is_running:
            return
        self._pulse_phase = (self._pulse_phase + 1) % 4
        if self.is_starting:
            frames = ["◴", "◷", "◶", "◵"]
            try:
                self.status_label.configure(
                    text=f"{frames[self._pulse_phase]} STARTING...",
                    text_color=YELLOW)
            except Exception:
                return
        elif self.is_running:
            dots = ["●", "◉", "●", "◉"]
            shades = {
                "3-hop": ["#5cb85c", "#7ed87e", "#5cb85c", "#4a9e4a"],
                "2-hop": ["#f0ad4e", "#f5c674", "#f0ad4e", "#c9923a"],
            }
            key = "2-hop" if self.chain_mode == "2-hop" else "3-hop"
            suffix = " (2-hop)" if self.chain_mode == "2-hop" else ""
            try:
                self.status_label.configure(
                    text=f"{dots[self._pulse_phase]} ACTIVE{suffix}",
                    text_color=shades[key][self._pulse_phase])
            except Exception:
                return
        self.after(400, self._pulse_tick)

    def check_status_thread(self):
        def run():
            while True:
                try:
                    res = subprocess.run(
                        ["machinectl", "show", CONTAINER_NAME, "-p", "State", "--value"],
                        capture_output=True, text=True, timeout=2)
                    running = (res.stdout.strip() == "running")
                    if (running != self.is_running
                            and not self.is_starting and not self.is_stopping):
                        self.is_running = running
                        self.after(0, self.update_ui_from_status)
                except Exception:
                    pass
                time.sleep(2)
        threading.Thread(target=run, daemon=True).start()

    def update_ui_from_status(self):
        if self.is_running:
            if self.chain_mode == "unknown":
                try:
                    out = subprocess.run(
                        ["journalctl", "-b", "-M", CONTAINER_NAME, "-u", "mc-runtime",
                         "--no-pager"],
                        capture_output=True, text=True, timeout=3).stdout
                    lines = [l for l in out.splitlines() if "chain: user ->" in l]
                    if lines:
                        self.chain_mode = "3-hop" if "3-hop" in lines[-1] else "2-hop"
                except Exception:
                    pass
            self.set_ui_state("running")
        else:
            self.set_ui_state("offline")

    def set_ui_state(self, state):
        if state == "starting":
            self.is_starting = True
            self.status_label.configure(text="◴ STARTING...", text_color=YELLOW)
            self.btn_start.configure(state="disabled")
            self.btn_stop.configure(state="disabled")
            self.pass_entry.configure(state="disabled")
            self._start_pulse()
        elif state == "stopping":
            self.is_stopping = True
            self.status_label.configure(text="◴ STOPPING...", text_color=YELLOW)
            self.btn_start.configure(state="disabled")
            self.btn_stop.configure(state="disabled")
        elif state == "running":
            self.is_running = True
            self.is_starting = False
            self.is_stopping = False
            self.btn_start.configure(state="disabled")
            self.btn_stop.configure(state="normal")
            self.pass_entry.configure(state="disabled")
            self.switch_to_desktop()
            self._start_pulse()
        else:
            self.is_running = False
            self.is_starting = False
            self.is_stopping = False
            self.chain_mode = "unknown"
            self._warned_2hop = False
            self.status_label.configure(text="● OFFLINE", text_color=RED)
            self.btn_start.configure(state="normal")
            self.btn_stop.configure(state="disabled")
            if not self.use_custom_var.get():
                self.pass_entry.configure(state="normal")
            self.tabview.set("Login & Connection")
            try:
                self.tabview._segmented_button._buttons_dict["Desktop"].configure(
                    state="disabled")
            except Exception:
                pass
    def read_output(self, process):
        for line in iter(process.stdout.readline, ''):
            self.log(line)
            if "Chain: 3-hop" in line:
                self.chain_mode = "3-hop"
            elif "Chain: 2-hop" in line:
                self.chain_mode = "2-hop"
            if "ALL REQUIRED CHECKS PASSED" in line:
                self.after(0, self.on_chain_ready)
        process.stdout.close()
        process.wait()
        if process.returncode == 0 and not self.is_stopping:
            self.after(0, lambda: self.set_ui_state("running"))
        elif not self.is_stopping:
            self.after(0, lambda: self.set_ui_state("offline"))
            self.log("\n[SYSTEM] Process exited unexpectedly.\n")
            self.after(0, lambda: self.notify(
                "Chain Failed",
                "The startup script exited before the chain was verified. "
                "Check the System Output for details.",
                kind="error"))

    def on_chain_ready(self):
        self.set_ui_state("running")
        self.log("\n[SYSTEM] Chain verified. Transitioning to Desktop...\n")
        self.after(1000, self.switch_to_desktop)
        if self.chain_mode == "2-hop":
            self.notify(
                "2-Hop Mode Only",
                "Exit VPN candidates were tried and failed. Your traffic is "
                "protected by ONE VPN hop + Tor. Restart later to retry.",
                kind="warning", duration=9000)
        else:
            self.notify(
                "Chain Verified",
                "3-hop chain is up: entry VPN → Tor → exit VPN. Desktop is ready.",
                kind="success")

    def switch_to_desktop(self):
        try:
            self.tabview._segmented_button._buttons_dict["Desktop"].configure(
                state="normal")
            self.tabview.set("Desktop")
            self.fetch_exit_ip()
        except Exception as e:
            self.log(f"[UI] Error switching to desktop: {e}\n")

    def fetch_exit_ip(self):
        def _fetch():
            try:
                pid = subprocess.run(
                    ["machinectl", "show", CONTAINER_NAME, "-p", "Leader", "--value"],
                    capture_output=True, text=True, timeout=2).stdout.strip()
                if pid:
                    self.container_pid = pid
                    out = subprocess.run(
                        ["sudo", "-n", "nsenter", "-t", pid, "-n",
                         "curl", "-s", "--max-time", "10",
                         "https://1.1.1.1/cdn-cgi/trace"],
                        capture_output=True, text=True, timeout=15).stdout
                    for line in out.splitlines():
                        if line.startswith("ip="):
                            self.exit_ip = line.split("=", 1)[1]
                            break
                    self.after(0, lambda: self.ip_label.configure(
                        text=f"Exit IP: {self.exit_ip}"))
            except Exception:
                pass
        threading.Thread(target=_fetch, daemon=True).start()
    def _get_container_pid(self):
        if self.container_pid:
            return self.container_pid
        try:
            pid = subprocess.run(
                ["machinectl", "show", CONTAINER_NAME, "-p", "Leader", "--value"],
                capture_output=True, text=True, timeout=2).stdout.strip()
            self.container_pid = pid
            return pid
        except Exception:
            return None

    def _sudo_ok(self):
        try:
            r = subprocess.run(["sudo", "-n", "true"], capture_output=True, timeout=5)
            return r.returncode == 0
        except Exception:
            return False

    def _setup_x11(self, pid):
        for cmd in (
            ["sudo", "-n", "nsenter", "-t", pid, "-a", "rm", "-rf", "/tmp/.X11-unix"],
            ["sudo", "-n", "nsenter", "-t", pid, "-a", "ln", "-sfn",
             "/run/host-x11", "/tmp/.X11-unix"],
        ):
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
                if r.returncode != 0:
                    self.log(f"[UI] X11 setup warning: {r.stderr.strip()}\n")
            except Exception as e:
                self.log(f"[UI] X11 setup error: {e}\n")

    def _launch_in_container(self, cmd_list, name):
        pid = self._get_container_pid()
        if not pid:
            self.notify("Not Running",
                        f"Start the chain before opening {name}.",
                        kind="warning")
            return False
        if not self._sudo_ok():
            messagebox.showerror(
                "Sudo password required",
                "Run `sudo -v` in a terminal, then try again.")
            return False

        display = os.environ.get("DISPLAY", ":0.0")
        self._setup_x11(pid)
        try:
            subprocess.run(["xhost", "+local:"], capture_output=True, timeout=5)
        except Exception:
            pass

        try:
            chk = subprocess.run(
                ["sudo", "-n", "nsenter", "-t", pid, "-a", "env",
                 f"DISPLAY={display}", "XAUTHORITY=/root/.Xauthority", "xset", "q"],
                capture_output=True, text=True, timeout=10)
            if chk.returncode == 0:
                self.log(f"[{name}] X11 OK inside container.\n")
            else:
                self.log(f"[{name}] X11 probe failed: {chk.stderr.strip()[:200]}\n")
        except Exception as e:
            self.log(f"[{name}] X11 probe error: {e}\n")

        full = [
            "sudo", "-n", "nsenter", "-t", pid, "-a", "env",
            f"DISPLAY={display}", "XAUTHORITY=/root/.Xauthority",
            "MOZ_DISABLE_CONTENT_SANDBOX=1",
            "MOZ_DISABLE_GPU_SANDBOX=1",
            "MOZ_DISABLE_RDD_SANDBOX=1",
            "MOZ_DISABLE_SHM=1",
            "LIBGL_ALWAYS_SOFTWARE=1",
            "LANG=C.UTF-8",
        ] + cmd_list
        self.log(f"[{name}] Launching: {' '.join(cmd_list)}\n")
        try:
            proc = subprocess.Popen(full, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
        except Exception as e:
            self.notify("Launch Failed", f"Could not spawn {name}: {e}", kind="error")
            return False

        def _reader():
            try:
                for line in iter(proc.stdout.readline, ''):
                    if line.strip():
                        self.log(f"[{name}] {line}")
            except Exception:
                pass
            finally:
                try:
                    rc = proc.wait()
                    if rc != 0:
                        self.log(f"[{name}] exited with code {rc}\n")
                        self.notify(f"{name} Closed",
                                    f"{name} exited with code {rc}. See System Output.",
                                    kind="error")
                except Exception:
                    pass
                try:
                    proc.stdout.close()
                except Exception:
                    pass
        threading.Thread(target=_reader, daemon=True).start()
        return True
    def launch_firefox(self):
        if "firefox" in self.launching:
            self.log("[UI] Firefox is already being launched...\n")
            return
        self.launching.add("firefox")
        try:
            self._launch_in_container(["firefox-esr", "--no-remote"], "Firefox")
        finally:
            self.after(30000, lambda: self.launching.discard("firefox"))

    def launch_terminal(self):
        if "terminal" in self.launching:
            self.log("[UI] Terminal is already being launched...\n")
            return
        self.launching.add("terminal")
        try:
            self._launch_in_container(["xterm"], "Terminal")
        finally:
            self.after(10000, lambda: self.launching.discard("terminal"))

    def launch_notepad(self):
        win = ctk.CTkToplevel(self)
        win.title("DwallKeep Notepad")
        win.geometry("600x400")
        win.configure(fg_color=BG_COLOR)

        txt = ctk.CTkTextbox(win, fg_color=CONSOLE_BG, text_color=CONSOLE_TEXT,
                             font=("Courier New", 12))
        txt.pack(fill="both", expand=True, padx=10, pady=10)

        menu = ctk.CTkFrame(win, fg_color=FRAME_COLOR)
        menu.pack(fill="x", padx=10, pady=(0, 10))

        def save_file():
            path = filedialog.asksaveasfilename(defaultextension=".txt")
            if path:
                with open(path, "w") as f:
                    f.write(txt.get("1.0", "end-1c"))
                self.notify("Saved", f"Notepad saved to {path}", kind="success")

        def load_file():
            path = filedialog.askopenfilename()
            if path:
                with open(path, "r") as f:
                    txt.delete("1.0", "end")
                    txt.insert("1.0", f.read())

        ctk.CTkButton(menu, text="Open", command=load_file, width=80
                      ).pack(side="left", padx=5)
        ctk.CTkButton(menu, text="Save", command=save_file, width=80
                      ).pack(side="left", padx=5)

    def launch_file_explorer(self):
        win = ctk.CTkToplevel(self)
        win.title("DwallKeep File Explorer")
        win.geometry("840x600")
        win.configure(fg_color=BG_COLOR)
        win.transient(self)

        top = ctk.CTkFrame(win, fg_color=FRAME_COLOR)
        top.pack(fill="x", padx=10, pady=(10, 5))
        path_var = tk.StringVar(value="/root")

        ctk.CTkButton(top, text="⬆ Up", width=60,
                      command=lambda: go_up()).pack(side="left", padx=(5, 2), pady=5)
        ctk.CTkButton(top, text="⟳ Reload", width=80,
                      command=lambda: load_dir(path_var.get())
                      ).pack(side="left", padx=2, pady=5)

        path_entry = ctk.CTkEntry(top, textvariable=path_var,
                                  fg_color=BG_COLOR, text_color=TEXT_COLOR)
        path_entry.pack(side="left", padx=5, pady=5, fill="x", expand=True)
        path_entry.bind("<Return>", lambda e: load_dir(path_var.get()))

        tree_frame = ctk.CTkFrame(win, fg_color=FRAME_COLOR)
        tree_frame.pack(fill="both", expand=True, padx=10, pady=5)
        tree = ttk.Treeview(tree_frame, columns=("type", "size"),
                            show="tree headings", height=20)
        tree.heading("#0", text="Name")
        tree.heading("type", text="Type")
        tree.heading("size", text="Size")
        tree.column("#0", width=380)
        tree.column("type", width=80)
        tree.column("size", width=100)
        tree.pack(fill="both", expand=True, padx=5, pady=5)

        style = ttk.Style()
        style.theme_use("clam")
        mode = ctk.get_appearance_mode().lower()
        if mode == "dark":
            style.configure("Treeview", background="#111", foreground="#ccc",
                            fieldbackground="#111", rowheight=25)
            style.configure("Treeview.Heading", background="#222", foreground="#fff")
        else:
            style.configure("Treeview", background="#ffffff", foreground="#222",
                            fieldbackground="#ffffff", rowheight=25)
            style.configure("Treeview.Heading", background="#e0e0e0",
                            foreground="#000")

        item_paths = {}

        def load_dir(d="/root"):
            tree.delete(*tree.get_children()); item_paths.clear()
            pid = self._get_container_pid()
            if not pid:
                return
            try:
                out = subprocess.run(
                    ["sudo", "-n", "nsenter", "-t", pid, "-a",
                     "ls", "-la", "--time-style=+%Y-%m-%d %H:%M", d],
                    capture_output=True, text=True, timeout=10).stdout
                for line in out.splitlines():
                    if line.startswith("total ") or not line.strip():
                        continue
                    parts = line.split(maxsplit=7)
                    if len(parts) < 8:
                        continue
                    perms, size, name = parts[0], parts[4], parts[7]
                    if " -> " in name:
                        name = name.split(" -> ")[0]
                    if name in (".", ".."):
                        continue
                    full = d.rstrip("/") + "/" + name
                    is_dir = perms.startswith("d")
                    iid = tree.insert("", "end", text=name,
                                      values=("Dir" if is_dir else "File", size))
                    item_paths[iid] = full
            except Exception as e:
                self.log(f"[Explorer] {e}\n")

        def sel_path():
            s = tree.selection()
            return item_paths.get(s[0]) if s else None

        def is_dir(p):
            pid = self._get_container_pid()
            if not pid or not p:
                return False
            return subprocess.run(
                ["sudo", "-n", "nsenter", "-t", pid, "-a", "test", "-d", p],
                capture_output=True, timeout=5).returncode == 0

        def on_double(_):
            p = sel_path()
            if p and is_dir(p):
                path_var.set(p); load_dir(p)

        def go_up():
            cur = path_var.get().rstrip("/") or "/"
            if cur == "/":
                return
            parent = os.path.dirname(cur) or "/"
            path_var.set(parent); load_dir(parent)

        def copy_to_host():
            p = sel_path()
            if not p or is_dir(p):
                return
            dest = filedialog.asksaveasfilename(
                parent=win, initialfile=os.path.basename(p))
            if not dest:
                return
            pid = self._get_container_pid()
            try:
                with open(dest, "wb") as f:
                    subprocess.run(
                        ["sudo", "-n", "nsenter", "-t", pid, "-a", "cat", p],
                        stdout=f, stderr=subprocess.PIPE, timeout=120, check=True)
                self.notify("Copied", f"Saved to host:\n{dest}", kind="success")
            except Exception as e:
                self.notify("Copy failed", str(e), kind="error")

        def copy_from_host():
            src = filedialog.askopenfilename(parent=win)
            if not src:
                return
            pid = self._get_container_pid()
            cur = path_var.get().rstrip("/") or "/"
            dest = (cur + "/" + os.path.basename(src)) if cur != "/" \
                   else "/" + os.path.basename(src)
            try:
                with open(src, "rb") as f:
                    subprocess.run(
                        ["sudo", "-n", "nsenter", "-t", pid, "-a", "tee", dest],
                        stdin=f, stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE, timeout=120, check=True)
                self.notify("Copied", f"Copied into container:\n{dest}",
                            kind="success")
                load_dir(cur)
            except Exception as e:
                self.notify("Copy failed", str(e), kind="error")

        def delete_sel():
            p = sel_path()
            if not p:
                return
            if not messagebox.askyesno("Delete", f"Delete '{p}'?", parent=win):
                return
            pid = self._get_container_pid()
            subprocess.run(
                ["sudo", "-n", "nsenter", "-t", pid, "-a", "rm", "-rf", p],
                capture_output=True, timeout=30)
            self.notify("Deleted", p, kind="info")
            load_dir(path_var.get())

        tree.bind("<Double-1>", on_double)

        bottom = ctk.CTkFrame(win, fg_color="transparent")
        bottom.pack(fill="x", padx=10, pady=(0, 10))
        ctk.CTkButton(bottom, text="← Copy to Host", width=140,
                      command=copy_to_host).pack(side="left", padx=2)
        ctk.CTkButton(bottom, text="Copy to Container →", width=160,
                      command=copy_from_host).pack(side="left", padx=2)
        ctk.CTkButton(bottom, text="Delete", width=80,
                      fg_color=RED, hover_color="#a03030",
                      command=delete_sel).pack(side="right", padx=2)

        load_dir("/root")
    def _check_cooldown_or_confirm(self):
        try:
            res = subprocess.run(
                ["sudo", "-n", "bash", SCRIPT_PATH, "--cooldown-status"],
                capture_output=True, text=True, timeout=5)
            remaining = int((res.stdout or "0").strip() or 0)
        except Exception:
            return False
        if remaining <= 0:
            return False

        try:
            res2 = subprocess.run(
                ["sudo", "-n", "bash", SCRIPT_PATH, "--override-status"],
                capture_output=True, text=True, timeout=5)
            status = {}
            for ln in (res2.stdout or "").strip().splitlines():
                if "=" in ln:
                    k, v = ln.split("=", 1)
                    status[k.strip()] = v.strip()
            overrides_left = int(status.get("remaining", 3))
            next_in = int(status.get("next_in", 0))
        except Exception:
            overrides_left, next_in = 3, 0

        mins, secs = divmod(remaining, 60)
        if overrides_left <= 0:
            mins2, secs2 = divmod(next_in, 60)
            self.notify("Override Limit Reached",
                        f"3 overrides used in the last 25 minutes. "
                        f"Wait {mins2}m {secs2}s.",
                        kind="warning")
            messagebox.showwarning(
                "Override Limit Reached",
                f"A chain was started {mins}m {secs}s ago.\n\n"
                f"VPNBook is a shared, personal-use resource.\n\n"
                f"You have used the override 3 times in the last 25 minutes.\n\n"
                f"Please wait {mins2}m {secs2}s before using override again.")
            return None

        return True if messagebox.askyesno(
            "Cooldown Active — Override?",
            f"A chain was started {mins}m {secs}s ago.\n\n"
            f"VPNBook is a shared, personal-use resource. Rapid reconnection "
            f"increases the risk of an IP ban that would break this tool for "
            f"everyone.\n\n"
            f"Overrides remaining: {overrides_left} of 3 (per 25 min).\n\n"
            f"Force start anyway?") else None

    def start_chain(self):
        if self.is_running:
            return

        use_custom = self.use_custom_var.get()
        env = os.environ.copy()

        if use_custom:
            entry = self.custom_entry_var.get().strip()
            exit_ = self.custom_exit_var.get().strip()
            auth = self.custom_auth_var.get().strip()
            if not entry or not exit_:
                messagebox.showerror(
                    "Missing files",
                    "Configure Entry and Exit .ovpn files in the 'Custom OVPN' tab.")
                return
            if not os.path.isfile(entry) or not os.path.isfile(exit_):
                messagebox.showerror(
                    "Missing files", "One or more selected .ovpn files do not exist.")
                return
            env["DWK_PROVIDER"] = "generic-ovpn"
            env["DWK_ENTRY_OVPN"] = entry
            env["DWK_EXIT_OVPN"] = exit_
            if auth and os.path.isfile(auth):
                env["DWK_AUTH_FILE"] = auth
            force = False
        else:
            password = self.pass_entry.get().strip()
            if not password:
                messagebox.showwarning("Input required",
                                       "Please enter the VPNBook password.")
                return
            env["VPNBOOK_PASSWORD"] = password
            force = self._check_cooldown_or_confirm()
            if force is None:
                return

        self.console.configure(state="normal")
        self.console.delete("0.0", "end")
        self.console.configure(state="disabled")
        self.set_ui_state("starting")
        self.log("Starting chain...\n")
        self.notify("Starting Chain",
                    "Bringing up entry VPN, Tor, and exit VPNs. This can take "
                    "several minutes.", kind="info", duration=4000)

        cmd = ["sudo", "-E", "bash", SCRIPT_PATH]
        if force:
            cmd.append("--force")

        try:
            self.process = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1, env=env)
            threading.Thread(target=self.read_output,
                             args=(self.process,), daemon=True).start()
        except Exception as e:
            self.log(f"Error starting script: {e}\n")
            self.notify("Launch Failed", str(e), kind="error")
            self.set_ui_state("offline")

    def stop_chain(self):
        if not messagebox.askyesno(
            "Stop Chain — Files Will Be Lost",
            "Stopping destroys the container.\n\n"
            "ANY FILES saved inside the container (home directory, Firefox "
            "downloads, /root, /tmp) will be PERMANENTLY LOST.\n\n"
            "Files you copied to the host via File Explorer are safe.\n\n"
            "Stop the chain?"):
            return
        self.set_ui_state("stopping")
        self.log("\nStopping chain...\n")
        self.notify("Stopping", "Tearing down the container.", kind="info")
        try:
            res = subprocess.run(["sudo", "bash", SCRIPT_PATH, "--stop"],
                                 capture_output=True, text=True)
            self.log(res.stdout)
            if res.stderr:
                self.log(res.stderr)
        except Exception as e:
            self.log(f"Error stopping: {e}\n")
        finally:
            self.process = None
            self.set_ui_state("offline")
            self.notify("Chain Stopped", "Container destroyed.", kind="info")

    def _on_close(self):
        if self.is_running:
            if not messagebox.askyesno(
                "Quit DwallKeep?",
                "The chain is still running.\n\n"
                "Quitting does NOT stop the chain — it keeps running in the "
                "background until you Stop it or reboot.\n\n"
                "Files inside the container will remain until you Stop.\n\n"
                "Quit anyway?"):
                return
        for t in list(Toast._active):
            try:
                t._destroy_self()
            except Exception:
                pass
        self.destroy()


if __name__ == "__main__":
    ctk.set_appearance_mode("dark")
    ctk.set_default_color_theme("blue")
    app = DwallKeepApp()
    app.mainloop()
