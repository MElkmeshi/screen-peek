using System.Runtime.InteropServices;
using static ScreenPeek.Native;
using Timer = System.Windows.Forms.Timer;

namespace ScreenPeek;

internal static class Injector
{
    public static bool Injecting { get; private set; }
    public static event Action? Started;
    public static event Action? Finished;

    private static Point? returnPoint;
    private static readonly Timer returnTimer = CreateReturnTimer();

    public static void Click(Point target, MouseButtons button)
    {
        var (down, up) = button switch
        {
            MouseButtons.Right => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
            MouseButtons.Middle => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
            _ => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        };
        Begin(target);
        Send(Mouse(down), Mouse(up));
        ScheduleReturn(80);
    }

    public static void Wheel(Point target, int delta)
    {
        Begin(target);
        Send(Mouse(MOUSEEVENTF_WHEEL, delta));
        ScheduleReturn(300);
    }

    private static void Begin(Point target)
    {
        returnTimer.Stop();
        if (returnPoint is null && GetCursorPos(out var p)) returnPoint = new Point(p.X, p.Y);
        if (!Injecting)
        {
            Injecting = true;
            Started?.Invoke();
        }
        SetCursorPos(target.X, target.Y);
    }

    private static void ScheduleReturn(int milliseconds)
    {
        returnTimer.Interval = milliseconds;
        returnTimer.Start();
    }

    private static Timer CreateReturnTimer()
    {
        var timer = new Timer();
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (returnPoint is { } p) SetCursorPos(p.X, p.Y);
            returnPoint = null;
            Injecting = false;
            Finished?.Invoke();
        };
        return timer;
    }

    private static INPUT Mouse(uint flags, int data = 0) =>
        new() { type = INPUT_MOUSE, mi = new MOUSEINPUT { dwFlags = flags, mouseData = data } };

    private static void Send(params INPUT[] inputs) =>
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
}

internal static class WindowMover
{
    public static bool IsMovable(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero || !IsWindow(hwnd) || !IsWindowVisible(hwnd)) return false;
        if (hwnd == GetShellWindow() || hwnd == GetDesktopWindow()) return false;
        GetWindowThreadProcessId(hwnd, out var pid);
        return pid != Environment.ProcessId;
    }

    public static bool Maximize(IntPtr hwnd, Screen screen)
    {
        if (!IsMovable(hwnd)) return false;
        var area = screen.WorkingArea;
        ShowWindow(hwnd, SW_RESTORE);
        SetWindowPos(hwnd, IntPtr.Zero, area.X, area.Y, area.Width, area.Height, SWP_NOZORDER | SWP_NOACTIVATE);
        ShowWindow(hwnd, SW_MAXIMIZE);
        return true;
    }

    public static bool Center(IntPtr hwnd, Screen? screen = null)
    {
        if (!IsMovable(hwnd)) return false;
        if (IsIconic(hwnd) || IsZoomed(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        var target = screen ?? Screen.FromHandle(hwnd);
        for (var pass = 0; pass < 2; pass++)
        {
            if (!GetWindowRect(hwnd, out var r)) return false;
            var area = target.WorkingArea;
            var w = Math.Min(r.Right - r.Left, area.Width);
            var h = Math.Min(r.Bottom - r.Top, area.Height);
            SetWindowPos(hwnd, IntPtr.Zero, area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h,
                SWP_NOZORDER | SWP_NOACTIVATE);
        }
        return true;
    }

    public static int FixWindowsSpanningScreens()
    {
        var candidates = new List<IntPtr>();
        EnumWindows((hwnd, _) =>
        {
            if (IsCandidate(hwnd)) candidates.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        var fixedCount = 0;
        foreach (var hwnd in candidates)
        {
            if (GetWindowRect(hwnd, out var r) && SpansScreens(Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom)) && Center(hwnd))
            {
                fixedCount++;
            }
        }
        return fixedCount;
    }

    public static bool Pull(Point point, Screen home)
    {
        var hwnd = GetAncestor(WindowFromPoint(new POINT { X = point.X, Y = point.Y }), GA_ROOT);
        if (!Center(hwnd, home)) return false;
        SetForegroundWindow(hwnd);
        return true;
    }

    private static bool IsCandidate(IntPtr hwnd)
    {
        if (!IsMovable(hwnd) || IsIconic(hwnd) || IsZoomed(hwnd) || GetWindowTextLength(hwnd) == 0) return false;
        var style = GetWindowLongPtr(hwnd, GWL_STYLE).ToInt64();
        var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
        if ((style & WS_CAPTION) != WS_CAPTION || (exStyle & WS_EX_TOOLWINDOW) != 0) return false;
        return DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out var cloaked, sizeof(int)) != 0 || cloaked == 0;
    }

    private static bool SpansScreens(Rectangle rect) =>
        Screen.AllScreens.Count(s =>
        {
            var overlap = Rectangle.Intersect(s.Bounds, rect);
            return overlap.Width >= 40 && overlap.Height >= 40;
        }) >= 2;
}

internal sealed class CursorLock : IDisposable
{
    private readonly Timer timer = new() { Interval = 250 };
    private readonly Func<Rectangle?> allowedArea;
    private bool enabled;

    public CursorLock(Func<Rectangle?> allowedArea)
    {
        this.allowedArea = allowedArea;
        timer.Tick += (_, _) => Apply();
        Injector.Started += Release;
        Injector.Finished += Apply;
    }

    public bool Enabled
    {
        get => enabled;
        set
        {
            enabled = value;
            timer.Enabled = value;
            if (value) Apply(); else Release();
        }
    }

    public void Apply()
    {
        if (!enabled || Injector.Injecting) return;
        if (allowedArea() is { } area)
        {
            var rect = new RECT(area);
            ClipCursor(ref rect);
        }
        else
        {
            Release();
        }
    }

    private static void Release() => ClipCursor(IntPtr.Zero);

    public void Dispose()
    {
        timer.Dispose();
        Release();
    }
}
