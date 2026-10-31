using System.Runtime.InteropServices;
using static OpenClicky.NativeMethods;

namespace OpenClicky;

/// <summary>
/// System-wide keyboard and mouse hooks (low-level, so they work while any app has focus).
///
/// - Hold Ctrl + Alt: push-to-talk. If another key is pressed while the chord is held
///   (Ctrl+Alt+Del, or AltGr typing a character), the talk session is cancelled instead.
/// - While talking, left-mouse drags draw ink on screen and are swallowed so the app
///   underneath doesn't also select or drag. Mouse movement itself is never blocked.
/// - Escape is reported (and passed through) so OpenClicky can stop talking.
///
/// Hook callbacks run on the thread that installed them (the WPF UI thread), so events
/// are raised on the UI thread.
/// </summary>
public sealed class GlobalInputHooks : IDisposable
{
    public event Action? TalkPressed;
    public event Action? TalkReleased;
    public event Action? TalkCancelledByOtherKey;
    public event Action? EscapePressed;
    public event Action<System.Drawing.Point>? InkStrokeBegan;
    public event Action<System.Drawing.Point>? InkStrokeMoved;
    public event Action<System.Drawing.Point>? InkStrokeEnded;

    private const uint VirtualKeyControl = 0x11;
    private const uint VirtualKeyAlt = 0x12;
    private const uint VirtualKeyLeftControl = 0xA2;
    private const uint VirtualKeyRightControl = 0xA3;
    private const uint VirtualKeyLeftAlt = 0xA4;
    private const uint VirtualKeyRightAlt = 0xA5;
    private const uint VirtualKeyEscape = 0x1B;

    // Kept as fields so the garbage collector never frees the delegates Windows is calling.
    private readonly LowLevelHookProcedure keyboardHookProcedure;
    private readonly LowLevelHookProcedure mouseHookProcedure;
    private IntPtr keyboardHookHandle;
    private IntPtr mouseHookHandle;

    private bool isControlHeld;
    private bool isAltHeld;
    private bool isInkStrokeInProgress;

    /// <summary>True while Ctrl + Alt is held for talking (and not cancelled).</summary>
    public bool IsTalkChordActive { get; private set; }

    public GlobalInputHooks()
    {
        keyboardHookProcedure = HandleKeyboardHookEvent;
        mouseHookProcedure = HandleMouseHookEvent;
    }

    public void Install()
    {
        var moduleHandle = GetModuleHandle(null);
        keyboardHookHandle = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardHookProcedure, moduleHandle, 0);
        mouseHookHandle = SetWindowsHookEx(WH_MOUSE_LL, mouseHookProcedure, moduleHandle, 0);
        if (keyboardHookHandle == IntPtr.Zero || mouseHookHandle == IntPtr.Zero)
        {
            Log.Write($"Couldn't install input hooks (error {Marshal.GetLastWin32Error()})");
        }
    }

    private IntPtr HandleKeyboardHookEvent(int hookCode, IntPtr messageIdentifier, IntPtr hookData)
    {
        if (hookCode >= 0)
        {
            var keyboardData = Marshal.PtrToStructure<KeyboardHookData>(hookData);
            var message = messageIdentifier.ToInt32();
            var isKeyDown = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
            var isKeyUp = message == WM_KEYUP || message == WM_SYSKEYUP;
            var virtualKeyCode = keyboardData.VirtualKeyCode;

            var isControlKey = virtualKeyCode is VirtualKeyControl or VirtualKeyLeftControl or VirtualKeyRightControl;
            var isAltKey = virtualKeyCode is VirtualKeyAlt or VirtualKeyLeftAlt or VirtualKeyRightAlt;

            if (isControlKey) isControlHeld = isKeyDown || (!isKeyUp && isControlHeld);
            if (isAltKey) isAltHeld = isKeyDown || (!isKeyUp && isAltHeld);

            if (isKeyDown && virtualKeyCode == VirtualKeyEscape)
            {
                SafelyRaise(EscapePressed);
            }

            if (IsTalkChordActive && isKeyDown && !isControlKey && !isAltKey)
            {
                // Ctrl+Alt+<key> is a shortcut or AltGr typing, not a request to talk.
                IsTalkChordActive = false;
                SafelyRaise(TalkCancelledByOtherKey);
            }
            else if (!IsTalkChordActive && isControlHeld && isAltHeld && isKeyDown && (isControlKey || isAltKey))
            {
                IsTalkChordActive = true;
                SafelyRaise(TalkPressed);
            }
            else if (IsTalkChordActive && (!isControlHeld || !isAltHeld))
            {
                IsTalkChordActive = false;
                SafelyRaise(TalkReleased);
            }
        }
        return CallNextHookEx(keyboardHookHandle, hookCode, messageIdentifier, hookData);
    }

    private IntPtr HandleMouseHookEvent(int hookCode, IntPtr messageIdentifier, IntPtr hookData)
    {
        if (hookCode >= 0)
        {
            var message = messageIdentifier.ToInt32();
            var mouseData = Marshal.PtrToStructure<MouseHookData>(hookData);
            var screenPoint = new System.Drawing.Point(mouseData.Point.X, mouseData.Point.Y);

            if (message == WM_LBUTTONDOWN && IsTalkChordActive)
            {
                isInkStrokeInProgress = true;
                SafelyRaise(InkStrokeBegan, screenPoint);
                return new IntPtr(1); // swallow: this click is for drawing
            }
            if (message == WM_MOUSEMOVE && isInkStrokeInProgress)
            {
                SafelyRaise(InkStrokeMoved, screenPoint);
                // never swallow movement, or the pointer would freeze
            }
            if (message == WM_LBUTTONUP && isInkStrokeInProgress)
            {
                isInkStrokeInProgress = false;
                SafelyRaise(InkStrokeEnded, screenPoint);
                return new IntPtr(1);
            }
        }
        return CallNextHookEx(mouseHookHandle, hookCode, messageIdentifier, hookData);
    }

    /// <summary>An exception escaping a hook callback would take down input handling; log it instead.</summary>
    private static void SafelyRaise(Action? handler)
    {
        try { handler?.Invoke(); } catch (Exception handlerError) { Log.Write($"Input handler error: {handlerError}"); }
    }

    private static void SafelyRaise(Action<System.Drawing.Point>? handler, System.Drawing.Point screenPoint)
    {
        try { handler?.Invoke(screenPoint); } catch (Exception handlerError) { Log.Write($"Input handler error: {handlerError}"); }
    }

    public void Dispose()
    {
        if (keyboardHookHandle != IntPtr.Zero) UnhookWindowsHookEx(keyboardHookHandle);
        if (mouseHookHandle != IntPtr.Zero) UnhookWindowsHookEx(mouseHookHandle);
        keyboardHookHandle = IntPtr.Zero;
        mouseHookHandle = IntPtr.Zero;
    }
}
