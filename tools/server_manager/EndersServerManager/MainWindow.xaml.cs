using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;

namespace EndersServerManager;

public partial class MainWindow : Window
{
    private AppSettings _settings = AppSettings.Load();
    private bool _busy;
    private bool _initialized;

    private static readonly Brush DotUnknown = new SolidColorBrush(Color.FromRgb(0x6B, 0x72, 0x80));
    private static readonly Brush DotOk = new SolidColorBrush(Color.FromRgb(0x3D, 0xDC, 0x84));
    private static readonly Brush DotBad = new SolidColorBrush(Color.FromRgb(0xFF, 0x54, 0x70));

    private const string StatusCommand =
        "if pgrep -f enders_server.x86_64 >/dev/null; then echo RUNNING; else echo STOPPED; fi; " +
        "if tmux has-session -t gameserver 2>/dev/null; then echo TMUX_OK; else echo TMUX_NONE; fi";

    private const string StopCommand =
        "tmux kill-session -t gameserver 2>/dev/null; pkill -f enders_server.x86_64 2>/dev/null; sleep 1; " +
        "if pgrep -f enders_server.x86_64 >/dev/null; then echo STILL_RUNNING; else echo STOPPED_OK; fi";

    public MainWindow()
    {
        InitializeComponent();
        PopulateFromSettings();
        UpdateFileInfo();
        _initialized = true;

        if (_settings.HasPassword)
        {
            Log("Settings loaded. Checking server status…");
            _ = RunStatusCheck(quiet: true);
        }
        else
        {
            Log("Welcome! First run: type the SSH password under Settings, click Save settings, then Test connection.");
        }
    }

    // ------------------------------------------------------------------ helpers

    private void Log(string msg)
    {
        Dispatcher.Invoke(() =>
        {
            LogBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {msg}\r\n");
            LogBox.ScrollToEnd();
        });
    }

    private void SetBusy(bool busy, string step = "Idle.")
    {
        _busy = busy;
        foreach (var b in new[] { DeployBtn, ReuploadBtn, StartBtn, StopBtn, LogBtn, StatusBtn, TestBtn, SaveBtn, BrowseBtn })
            b.IsEnabled = !busy;
        StepText.Text = step;
    }

    private bool ReadyForSsh()
    {
        if (!_settings.HasPassword)
        {
            Log("✗ No SSH password saved yet — enter it under Settings and click Save settings.");
            return false;
        }
        return true;
    }

    private async Task Guarded(Func<Task> action, string step)
    {
        if (_busy || !ReadyForSsh())
            return;
        SetBusy(true, step);
        try
        {
            await action();
        }
        catch (Exception ex)
        {
            Log($"✗ {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            SetBusy(false);
        }
    }

    private async Task<(int Code, string Output)> ExecAsync(string command, int timeoutSeconds = 30)
    {
        var svc = new SshService(_settings);
        return await Task.Run(() => svc.Exec(command, timeoutSeconds));
    }

    // ------------------------------------------------------------------ status

    private async Task RunStatusCheck(bool quiet = false)
    {
        if (!_settings.HasPassword)
            return;
        try
        {
            var (_, output) = await ExecAsync(StatusCommand, 20);
            bool running = output.Contains("RUNNING") && !output.Contains("STILL_RUNNING");
            bool tmuxOk = output.Contains("TMUX_OK");
            StatusDot.Fill = running ? DotOk : DotBad;
            StatusText.Text = running
                ? (tmuxOk ? "server running" : "server running (no tmux session)")
                : "server stopped";
            if (!quiet)
                Log($"Status: {StatusText.Text}.");
        }
        catch (Exception ex)
        {
            StatusDot.Fill = DotUnknown;
            StatusText.Text = "unreachable";
            if (!quiet)
                Log($"✗ Status check failed: {ex.Message}");
        }
    }

    // ------------------------------------------------------------------ core steps

    private async Task<bool> StopServerCore()
    {
        Log("Stopping server (tmux kill-session + pkill)…");
        var (_, output) = await ExecAsync(StopCommand, 25);
        if (output.Contains("STOPPED_OK"))
        {
            Log("✓ Server stopped — the binary on the VPS is unlocked.");
            return true;
        }
        Log($"✗ A server process is STILL RUNNING after the stop attempt: {output}");
        return false;
    }

    private async Task<bool> UploadCore()
    {
        var fi = new FileInfo(_settings.LocalBinaryPath);
        if (!fi.Exists)
        {
            Log($"✗ Local binary not found: {_settings.LocalBinaryPath}");
            return false;
        }

        long total = fi.Length;
        Log($"Uploading {fi.Name}  ({total:N0} bytes, exported {fi.LastWriteTime:g})  →  {_settings.RemoteBinaryPath} …");
        UploadBar.Value = 0;
        ProgressPct.Text = "0%";
        TransferText.Text = "";
        var sw = Stopwatch.StartNew();

        IProgress<ulong> progress = new Progress<ulong>(sent =>
        {
            double pct = total > 0 ? Math.Min(sent * 100.0 / total, 100.0) : 0.0;
            UploadBar.Value = pct;
            ProgressPct.Text = $"{pct:F0}%";
            double secs = Math.Max(sw.Elapsed.TotalSeconds, 0.001);
            TransferText.Text = $"{sent / 1048576.0:F1} / {total / 1048576.0:F1} MB   •   {sent / 1048576.0 / secs:F1} MB/s";
        });

        var svc = new SshService(_settings);
        long remoteSize = await Task.Run(() => svc.UploadBinary(fi, _settings.RemoteBinaryPath, b => progress.Report(b)));

        UploadBar.Value = 100;
        ProgressPct.Text = "100%";
        Log($"Upload finished in {sw.Elapsed.TotalSeconds:F1} s. Verifying the remote size…");

        if (remoteSize == total)
        {
            Log($"✓ Remote size matches local ({remoteSize:N0} bytes) — the new build landed.");
            return true;
        }
        Log($"✗ SIZE MISMATCH: local {total:N0} vs remote {remoteSize:N0} bytes — the upload did NOT land. Stop the server and reupload.");
        return false;
    }

    private async Task StartCore()
    {
        Log($"Starting server on port {_settings.GamePort} (chmod +x && run_server.sh)…");
        var cmd = $"cd {_settings.RemoteDirectory} && chmod +x enders_server.x86_64 && ./run_server.sh {_settings.GamePort}";
        var (_, output) = await ExecAsync(cmd, 30);
        if (output.Length > 0)
            Log(output);

        await Task.Delay(1500);
        await RunStatusCheck(quiet: true);
        Log(StatusText.Text.StartsWith("server running")
            ? "✓ Server is up."
            : "✗ Server did not come up — use 'Fetch server log' to see why.");
    }

    private async Task FetchLogCore()
    {
        Log("Fetching the last server output (tmux capture-pane)…");
        var (_, output) = await ExecAsync(
            "tmux capture-pane -pt gameserver -S -200 2>/dev/null || echo '(no gameserver tmux session — server not running under tmux)'", 25);
        var trimmed = output.Trim();
        Log(trimmed.Length == 0
            ? "(the server pane is empty)"
            : "── SERVER LOG ─────────────────────────────\r\n" + trimmed + "\r\n───────────────────────────────────────────");
    }

    // ------------------------------------------------------------------ button handlers

    private async void DeployClicked(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        Log("═══ DEPLOY: stop → upload → verify → start ═══");
        if (!await StopServerCore())
        {
            Log("Deploy aborted — uploading over a running binary silently keeps the OLD build (text file busy).");
            return;
        }
        if (!await UploadCore())
        {
            Log("Deploy aborted at verification.");
            return;
        }
        await StartCore();
        Log("═══ DEPLOY COMPLETE ═══");
    }, "Deploying…");

    private async void ReuploadClicked(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        Log("═══ REUPLOAD: stop → upload → verify (no start) ═══");
        if (!await StopServerCore())
        {
            Log("Reupload aborted — the binary is still locked by a running process.");
            return;
        }
        if (await UploadCore())
            Log("Reupload done. Hit 'Start server' when ready.");
        await RunStatusCheck(quiet: true);
    }, "Reuploading…");

    private async void StartClicked(object sender, RoutedEventArgs e) =>
        await Guarded(StartCore, "Starting server…");

    private async void StopClicked(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        await StopServerCore();
        await RunStatusCheck(quiet: true);
    }, "Stopping server…");

    private async void FetchLogClicked(object sender, RoutedEventArgs e) =>
        await Guarded(FetchLogCore, "Fetching server log…");

    private async void StatusClicked(object sender, RoutedEventArgs e) =>
        await Guarded(() => RunStatusCheck(), "Checking status…");

    private async void TestConnectionClicked(object sender, RoutedEventArgs e) => await Guarded(async () =>
    {
        Log($"Testing SSH connection to {_settings.Username}@{_settings.Host}:{_settings.SshPort} …");
        var (_, output) = await ExecAsync("echo CONNECTED_OK && uname -a", 20);
        Log(output.Contains("CONNECTED_OK")
            ? $"✓ Connected: {output.Replace("CONNECTED_OK", "").Trim()}"
            : $"✗ Unexpected reply: {output}");
        await RunStatusCheck(quiet: true);
    }, "Testing connection…");

    private void ClearLogClicked(object sender, RoutedEventArgs e) => LogBox.Clear();

    // ------------------------------------------------------------------ settings + file picker

    private void PopulateFromSettings()
    {
        HostBox.Text = _settings.Host;
        PortBox.Text = _settings.SshPort.ToString();
        UserBox.Text = _settings.Username;
        RemoteDirBox.Text = _settings.RemoteDirectory;
        GamePortBox.Text = _settings.GamePort.ToString();
        PathBox.Text = _settings.LocalBinaryPath;
        RefreshHeaderAndPwdHint();
    }

    private void RefreshHeaderAndPwdHint()
    {
        HeaderHost.Text = $"{_settings.Username}@{_settings.Host}   •   ssh {_settings.SshPort}   •   game udp {_settings.GamePort}";
        PwdSavedText.Text = _settings.HasPassword ? "✓ password saved (encrypted)" : "no password saved yet";
        PwdSavedText.Foreground = _settings.HasPassword ? (Brush)FindResource("Ok") : (Brush)FindResource("Danger");
    }

    private void SaveSettingsClicked(object sender, RoutedEventArgs e)
    {
        if (!int.TryParse(PortBox.Text.Trim(), out int sshPort) || sshPort <= 0 || sshPort > 65535)
        {
            Log("✗ SSH port must be a number between 1 and 65535.");
            return;
        }
        if (!int.TryParse(GamePortBox.Text.Trim(), out int gamePort) || gamePort <= 0 || gamePort > 65535)
        {
            Log("✗ Game port must be a number between 1 and 65535.");
            return;
        }

        _settings.Host = HostBox.Text.Trim();
        _settings.SshPort = sshPort;
        _settings.Username = UserBox.Text.Trim();
        _settings.RemoteDirectory = string.IsNullOrWhiteSpace(RemoteDirBox.Text) ? "/root" : RemoteDirBox.Text.Trim();
        _settings.GamePort = gamePort;
        _settings.LocalBinaryPath = PathBox.Text.Trim();

        if (PwdBox.Password.Length > 0)
        {
            _settings.SetPassword(PwdBox.Password);
            PwdBox.Clear();
        }

        _settings.Save();
        RefreshHeaderAndPwdHint();
        Log(_settings.HasPassword
            ? "✓ Settings saved (password stored encrypted with Windows DPAPI)."
            : "✓ Settings saved — but no password yet, so nothing can connect.");
    }

    private void BrowseClicked(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Title = "Pick the exported Linux server binary",
            Filter = "Linux server binary (*.x86_64)|*.x86_64|All files (*.*)|*.*"
        };
        try
        {
            var dir = Path.GetDirectoryName(_settings.LocalBinaryPath);
            if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir))
                dlg.InitialDirectory = dir;
        }
        catch { }

        if (dlg.ShowDialog() == true)
            PathBox.Text = dlg.FileName;
    }

    private void PathChanged(object sender, TextChangedEventArgs e)
    {
        UpdateFileInfo();
        if (!_initialized)
            return;
        _settings.LocalBinaryPath = PathBox.Text.Trim();
        try { _settings.Save(); } catch { }
    }

    private void UpdateFileInfo()
    {
        try
        {
            var fi = new FileInfo(PathBox.Text.Trim());
            if (fi.Exists)
            {
                FileInfoText.Text = $"{fi.Length:N0} bytes   •   exported {fi.LastWriteTime:g}";
                FileInfoText.Foreground = (Brush)FindResource("Ok");
            }
            else
            {
                FileInfoText.Text = "file not found — export the Linux build from Godot first";
                FileInfoText.Foreground = (Brush)FindResource("Danger");
            }
        }
        catch
        {
            FileInfoText.Text = "invalid path";
            FileInfoText.Foreground = (Brush)FindResource("Danger");
        }
    }
}
