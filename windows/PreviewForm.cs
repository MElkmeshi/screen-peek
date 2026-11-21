using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Media;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using static ScreenPeek.Native;
using Timer = System.Windows.Forms.Timer;

namespace ScreenPeek;

internal sealed class PreviewForm : Form
{
    private const uint HotKeyModifiers = MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT;
    private const int HotKeyPreview = 1, HotKeySend = 2, HotKeyBack = 3, HotKeyLock = 4, HotKeyCenter = 5, HotKeyFix = 6;
    private const string IdleHint = "Ctrl-click a window to pull it here";
    private static readonly (int Id, Keys Key)[] HotKeyMap =
    [
        (HotKeyPreview, Keys.P), (HotKeySend, Keys.Right), (HotKeyBack, Keys.Left),
        (HotKeyLock, Keys.L), (HotKeyCenter, Keys.C), (HotKeyFix, Keys.F),
    ];

    private readonly Timer captureTimer = new() { Interval = 66 };
    private readonly Timer flashTimer = new() { Interval = 250 };
    private readonly NotifyIcon tray = new();
    private readonly NoActivateToolStrip toolbar = new();
    private readonly ToolStripLabel statusLabel = new(IdleHint);
    private readonly Timer statusTimer = new() { Interval = 3000 };
    private IntPtr lastForeground;
    private readonly CursorLock cursorLock;
    private Bitmap? frame;
    private byte[] previousPixels = [];
    private byte[] currentPixels = [];
    private string? targetDevice;
    private bool flashOnChange = true;
    private bool flashing;
    private bool exiting;

    public PreviewForm()
    {
        Text = "ScreenPeek";
        FormBorderStyle = FormBorderStyle.SizableToolWindow;
        ShowInTaskbar = false;
        TopMost = true;
        DoubleBuffered = true;
        BackColor = Color.Black;
        StartPosition = FormStartPosition.Manual;
        BuildToolbar();
        ClientSize = LogicalToDeviceUnits(new Size(480, 270)) + new Size(0, toolbar.Height);
        MinimumSize = LogicalToDeviceUnits(new Size(200, 140));
        var area = Screen.PrimaryScreen!.WorkingArea;
        Location = new Point(area.Right - Width - 16, area.Bottom - Height - 16);

        cursorLock = new CursorLock(AllowedCursorArea);
        captureTimer.Tick += (_, _) =>
        {
            TrackForeground();
            CaptureFrame();
        };
        statusTimer.Tick += (_, _) =>
        {
            statusTimer.Stop();
            statusLabel.Text = IdleHint;
        };
        flashTimer.Tick += (_, _) =>
        {
            flashTimer.Stop();
            flashing = false;
            Invalidate();
        };
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;

        BuildTray();
        SelectTarget();
        captureTimer.Start();
    }

    private Screen? Target => Screen.AllScreens.FirstOrDefault(s => s.DeviceName == targetDevice);

    protected override bool ShowWithoutActivation => true;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
            return cp;
        }
    }

    protected override void WndProc(ref Message m)
    {
        switch (m.Msg)
        {
            case WM_MOUSEACTIVATE:
                m.Result = MA_NOACTIVATE;
                return;
            case WM_HOTKEY:
                HandleHotKey((int)m.WParam);
                return;
            default:
                base.WndProc(ref m);
                return;
        }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        var failed = HotKeyMap.Where(h => !RegisterHotKey(Handle, h.Id, HotKeyModifiers, (uint)h.Key)).Select(h => h.Key).ToList();
        if (failed.Count > 0)
        {
            tray.ShowBalloonTip(5000, "ScreenPeek", $"These hotkeys are taken by another app: Ctrl+Alt+Shift+{string.Join(", ", failed)}", ToolTipIcon.Warning);
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!exiting && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
        foreach (var (id, _) in HotKeyMap) UnregisterHotKey(Handle, id);
        captureTimer.Dispose();
        statusTimer.Dispose();
        flashTimer.Dispose();
        cursorLock.Dispose();
        tray.Visible = false;
        tray.Dispose();
        frame?.Dispose();
        base.OnFormClosed(e);
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (TargetPoint(e.Location) is not { } point) return;
        if (e.Button == MouseButtons.Left && (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0)
        {
            if (WindowMover.Pull(point, HomeScreen())) Notify("Pulled window to this screen");
            else Fail("No window there");
            return;
        }
        Injector.Click(point, e.Button);
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        if (TargetPoint(e.Location) is { } point) Injector.Wheel(point, e.Delta);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Color.Black);
        if (Target is not { } target)
        {
            TextRenderer.DrawText(g, "No second screen connected.\nRight-click the ScreenPeek tray icon → Target Screen to test with this one.",
                Font, PreviewArea(), Color.Gray, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
            return;
        }

        var rect = ContentRect();
        if (frame is not null && frame.Size == rect.Size) g.DrawImageUnscaled(frame, rect.Location);
        DrawCursor(g, target, rect);
        if (flashing)
        {
            using var pen = new Pen(Color.Red, 3);
            g.DrawRectangle(pen, rect.X + 1, rect.Y + 1, rect.Width - 3, rect.Height - 3);
        }
    }

    private void OnDisplaySettingsChanged(object? sender, EventArgs e)
    {
        if (IsHandleCreated) BeginInvoke(SelectTarget);
    }

    private void SelectTarget()
    {
        if (Target is null) targetDevice = Screen.AllScreens.FirstOrDefault(s => !s.Primary)?.DeviceName;
        Text = Target is { } t ? ScreenName(t) : "ScreenPeek";
        previousPixels = [];
        cursorLock.Apply();
        Invalidate();
    }

    private static string ScreenName(Screen s) =>
        $"{s.DeviceName.TrimStart('\\', '.')}  {s.Bounds.Width}×{s.Bounds.Height}{(s.Primary ? "  (main)" : "")}";

    private Screen HomeScreen()
    {
        var home = Screen.FromControl(this);
        return home.DeviceName == targetDevice ? Screen.PrimaryScreen! : home;
    }

    private Rectangle? AllowedCursorArea()
    {
        if (Target is null) return null;
        var home = HomeScreen();
        return home.DeviceName == targetDevice ? null : home.Bounds;
    }

    private Rectangle PreviewArea()
    {
        var client = ClientRectangle;
        client.Height = Math.Max(0, client.Height - toolbar.Height);
        return client;
    }

    private Rectangle ContentRect()
    {
        var client = PreviewArea();
        if (Target is not { } target || client.Width < 2 || client.Height < 2) return client;
        var b = target.Bounds;
        var scale = Math.Min((double)client.Width / b.Width, (double)client.Height / b.Height);
        var w = Math.Max(1, (int)(b.Width * scale));
        var h = Math.Max(1, (int)(b.Height * scale));
        return new Rectangle(client.X + (client.Width - w) / 2, client.Y + (client.Height - h) / 2, w, h);
    }

    private Point? TargetPoint(Point client)
    {
        if (Target is not { } target) return null;
        var rect = ContentRect();
        if (!rect.Contains(client)) return null;
        var b = target.Bounds;
        var x = b.X + (int)((long)(client.X - rect.X) * (b.Width - 1) / Math.Max(1, rect.Width - 1));
        var y = b.Y + (int)((long)(client.Y - rect.Y) * (b.Height - 1) / Math.Max(1, rect.Height - 1));
        return new Point(x, y);
    }

    private void CaptureFrame()
    {
        if (!Visible || WindowState == FormWindowState.Minimized || Target is not { } target) return;
        var dst = ContentRect();
        if (dst.Width < 2 || dst.Height < 2) return;
        if (frame is null || frame.Size != dst.Size)
        {
            frame?.Dispose();
            frame = new Bitmap(dst.Width, dst.Height, PixelFormat.Format32bppRgb);
            previousPixels = [];
        }

        using (var g = Graphics.FromImage(frame))
        {
            var hdc = g.GetHdc();
            var screenDc = GetDC(IntPtr.Zero);
            try
            {
                SetStretchBltMode(hdc, HALFTONE);
                SetBrushOrgEx(hdc, 0, 0, IntPtr.Zero);
                var b = target.Bounds;
                StretchBlt(hdc, 0, 0, dst.Width, dst.Height, screenDc, b.X, b.Y, b.Width, b.Height, SRCCOPY);
            }
            finally
            {
                ReleaseDC(IntPtr.Zero, screenDc);
                g.ReleaseHdc(hdc);
            }
        }

        if (flashOnChange && FrameChanged())
        {
            flashing = true;
            flashTimer.Stop();
            flashTimer.Start();
        }
        Invalidate();
    }

    private bool FrameChanged()
    {
        var data = frame!.LockBits(new Rectangle(Point.Empty, frame.Size), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
        try
        {
            var length = Math.Abs(data.Stride) * data.Height;
            if (currentPixels.Length != length) currentPixels = new byte[length];
            Marshal.Copy(data.Scan0, currentPixels, 0, length);
        }
        finally
        {
            frame.UnlockBits(data);
        }
        var changed = previousPixels.Length == currentPixels.Length && !currentPixels.AsSpan().SequenceEqual(previousPixels);
        (previousPixels, currentPixels) = (currentPixels, previousPixels);
        return changed;
    }

    private static void DrawCursor(Graphics g, Screen target, Rectangle rect)
    {
        if (!GetCursorPos(out var p)) return;
        var b = target.Bounds;
        if (!b.Contains(p.X, p.Y)) return;
        var x = rect.X + (p.X - b.X) * rect.Width / (float)b.Width;
        var y = rect.Y + (p.Y - b.Y) * rect.Height / (float)b.Height;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var fill = new SolidBrush(Color.FromArgb(220, Color.OrangeRed));
        using var outline = new Pen(Color.White, 1.5f);
        g.FillEllipse(fill, x - 5, y - 5, 10, 10);
        g.DrawEllipse(outline, x - 5, y - 5, 10, 10);
    }

    private void HandleHotKey(int id)
    {
        switch (id)
        {
            case HotKeyPreview: TogglePreview(); break;
            case HotKeySend: SendFrontWindow(); break;
            case HotKeyBack: BringFrontWindowBack(); break;
            case HotKeyLock: cursorLock.Enabled = !cursorLock.Enabled; break;
            case HotKeyCenter: CenterFrontWindow(); break;
            case HotKeyFix: FixStuckWindows(); break;
        }
    }

    private void TogglePreview()
    {
        if (Visible) Hide(); else Show();
    }

    private void SendFrontWindow()
    {
        if (Target is { } target && WindowMover.Maximize(CurrentWindow(), target)) Notify($"Sent to {target.DeviceName.TrimStart('\\', '.')}");
        else Fail("No window to send");
    }

    private void BringFrontWindowBack()
    {
        if (WindowMover.Center(CurrentWindow(), HomeScreen())) Notify("Brought window back");
        else Fail("No window to bring back");
    }

    private void CenterFrontWindow()
    {
        if (WindowMover.Center(CurrentWindow())) Notify("Centered");
        else Fail("No window to center");
    }

    private void FixStuckWindows()
    {
        var count = WindowMover.FixWindowsSpanningScreens();
        Notify(count == 0 ? "No stuck windows" : $"Fixed {count} window{(count == 1 ? "" : "s")}");
    }

    private IntPtr CurrentWindow()
    {
        var foreground = GetForegroundWindow();
        return WindowMover.IsMovable(foreground) ? foreground : lastForeground;
    }

    private void TrackForeground()
    {
        var foreground = GetForegroundWindow();
        if (WindowMover.IsMovable(foreground)) lastForeground = foreground;
    }

    private void Notify(string message)
    {
        statusLabel.Text = message;
        statusTimer.Stop();
        statusTimer.Start();
    }

    private void Fail(string message)
    {
        SystemSounds.Beep.Play();
        Notify(message);
    }

    private void BuildToolbar()
    {
        toolbar.Dock = DockStyle.Bottom;
        toolbar.GripStyle = ToolStripGripStyle.Hidden;
        toolbar.RenderMode = ToolStripRenderMode.System;
        toolbar.CanOverflow = false;
        AddToolbarButton("Send \u2192", "Send the window you're using to the target screen (Ctrl+Alt+Shift+\u2192)", SendFrontWindow);
        AddToolbarButton("\u2190 Back", "Bring the window you're using back to this screen (Ctrl+Alt+Shift+\u2190)", BringFrontWindowBack);
        AddToolbarButton("Center", "Center the window you're using on its screen (Ctrl+Alt+Shift+C)", CenterFrontWindow);
        AddToolbarButton("Fix Stuck", "Move every window that sits across two screens fully onto one screen (Ctrl+Alt+Shift+F)", FixStuckWindows);
        statusLabel.ForeColor = SystemColors.GrayText;
        statusLabel.ToolTipText = "Ctrl-click a window in the preview to pull it onto this screen";
        toolbar.Items.Add(statusLabel);
        Controls.Add(toolbar);
    }

    private void AddToolbarButton(string text, string tip, Action action)
    {
        var button = new ToolStripButton(text) { ToolTipText = tip, DisplayStyle = ToolStripItemDisplayStyle.Text };
        button.Click += (_, _) => action();
        toolbar.Items.Add(button);
    }

    private void BuildTray()
    {
        tray.Icon = LoadIcon(SystemInformation.SmallIconSize);
        Icon = LoadIcon(SystemInformation.IconSize);
        tray.Text = "ScreenPeek";
        var menu = new ContextMenuStrip();
        menu.Opening += (_, _) => FillMenu(menu);
        tray.ContextMenuStrip = menu;
        tray.MouseDoubleClick += (_, _) => TogglePreview();
        tray.Visible = true;
    }

    private void FillMenu(ContextMenuStrip menu)
    {
        menu.Items.Clear();
        AddItem(menu, Visible ? "Hide Preview" : "Show Preview", "Ctrl+Alt+Shift+P", TogglePreview);
        AddItem(menu, "Keep Cursor Off Target Screen", "Ctrl+Alt+Shift+L", () => cursorLock.Enabled = !cursorLock.Enabled)
            .Checked = cursorLock.Enabled;
        AddItem(menu, "Flash Border When Screen Changes", null, () => flashOnChange = !flashOnChange).Checked = flashOnChange;
        AddItem(menu, "Fix Windows Stuck Across Screens", "Ctrl+Alt+Shift+F", FixStuckWindows);
        AddItem(menu, "Center Last Used Window", "Ctrl+Alt+Shift+C", CenterFrontWindow);
        menu.Items.Add(new ToolStripMenuItem("Move window: Ctrl+Alt+Shift+→ to target, ← back") { Enabled = false });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Target Screen") { Enabled = false });
        foreach (var screen in Screen.AllScreens)
        {
            var device = screen.DeviceName;
            AddItem(menu, "    " + ScreenName(screen), null, () =>
            {
                targetDevice = device;
                SelectTarget();
            }).Checked = device == targetDevice;
        }
        menu.Items.Add(new ToolStripSeparator());
        AddItem(menu, "Exit ScreenPeek", null, () =>
        {
            exiting = true;
            Close();
        });
    }

    private static ToolStripMenuItem AddItem(ContextMenuStrip menu, string text, string? shortcut, Action action)
    {
        var item = new ToolStripMenuItem(text) { ShortcutKeyDisplayString = shortcut };
        item.Click += (_, _) => action();
        menu.Items.Add(item);
        return item;
    }

    private static Icon LoadIcon(Size size)
    {
        using var stream = typeof(PreviewForm).Assembly.GetManifestResourceStream("ScreenPeek.ico")!;
        return new Icon(stream, size);
    }
}

internal sealed class NoActivateToolStrip : ToolStrip
{
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_MOUSEACTIVATE)
        {
            m.Result = MA_NOACTIVATE;
            return;
        }
        base.WndProc(ref m);
    }
}
