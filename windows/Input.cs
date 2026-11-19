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
    public static bool MoveForegroundWindow(Screen screen)
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero || hwnd == GetShellWindow() || hwnd == GetDesktopWindow()) return false;
        GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == Environment.ProcessId) return false;

        var area = screen.WorkingArea;
        ShowWindow(hwnd, SW_RESTORE);
        SetWindowPos(hwnd, IntPtr.Zero, area.X, area.Y, area.Width, area.Height, SWP_NOZORDER | SWP_NOACTIVATE);
        ShowWindow(hwnd, SW_MAXIMIZE);
        return true;
    }
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
