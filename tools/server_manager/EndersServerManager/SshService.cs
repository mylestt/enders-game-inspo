using System;
using System.IO;
using Renci.SshNet;

namespace EndersServerManager;

// Thin wrapper over SSH.NET: one short-lived connection per operation. Password auth
// plus keyboard-interactive (some sshd configs only offer the latter), both answered
// from the DPAPI-decrypted password.
public class SshService
{
    private readonly AppSettings _s;

    public SshService(AppSettings settings) => _s = settings;

    private ConnectionInfo BuildConnectionInfo()
    {
        var pass = _s.GetPassword();
        var pw = new PasswordAuthenticationMethod(_s.Username, pass);
        var kb = new KeyboardInteractiveAuthenticationMethod(_s.Username);
        kb.AuthenticationPrompt += (_, e) =>
        {
            foreach (var prompt in e.Prompts)
                prompt.Response = pass;
        };
        return new ConnectionInfo(_s.Host, _s.SshPort, _s.Username, pw, kb)
        {
            Timeout = TimeSpan.FromSeconds(15)
        };
    }

    public (int ExitCode, string Output) Exec(string command, int timeoutSeconds = 30)
    {
        using var client = new SshClient(BuildConnectionInfo());
        client.Connect();
        using var cmd = client.CreateCommand(command);
        cmd.CommandTimeout = TimeSpan.FromSeconds(timeoutSeconds);
        var stdout = cmd.Execute();
        var stderr = cmd.Error;
        object? status = cmd.ExitStatus;   // int on older SSH.NET, int? on newer — box both
        int code = status is null ? -1 : Convert.ToInt32(status);
        client.Disconnect();

        var output = string.IsNullOrWhiteSpace(stderr)
            ? stdout
            : (stdout.Length == 0 ? stderr : stdout.TrimEnd('\n') + "\n" + stderr);
        return (code, output.Trim());
    }

    // Uploads via SFTP (overwrites), streaming progress as bytes-sent, then returns the
    // remote file's size so the caller can verify the upload actually landed.
    public long UploadBinary(FileInfo local, string remotePath, Action<ulong> progress)
    {
        using var sftp = new SftpClient(BuildConnectionInfo());
        sftp.Connect();
        sftp.OperationTimeout = TimeSpan.FromMinutes(15);
        using (var fs = local.OpenRead())
            sftp.UploadFile(fs, remotePath, bytesSent => progress(bytesSent));
        long remoteSize = sftp.GetAttributes(remotePath).Size;
        sftp.Disconnect();
        return remoteSize;
    }
}
