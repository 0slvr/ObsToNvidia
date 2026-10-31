using System.Text;
using System.Text.RegularExpressions;

// Joins src\*.lua (in the order listed in src\_order.txt) into dist\obs_to_nvidia.lua.
// Usage: obs_to_nvidia [projectRoot] [--copy-to <folder>] [--no-check]
//                      [--publish [--yes] [--no-bump]]
//   --publish  : auto-bump VERSION, build, commit + push, create the GitHub Release.
//                (no console window; output goes to publish.log and the VS Output window)
//   --no-bump  : publish with the VERSION already in the file (don't increase it).

bool isPublish = args.Contains("--publish");
int code;
try { code = Go(args); }
catch (Exception ex) { Console.Error.WriteLine("FATAL: " + ex); code = 1; }

// Publish mode has no console window: a failure is shown in a message box
// (code 2 = cancelled by the user, nothing to report). Everything is also in publish.log.
if (isPublish && code != 0 && code != 2)
    NativeMethods.Show("obs_to_nvidia - publish FAILED", PublishLog.Tail());
return code;

static int Go(string[] args)
{
    const string OutName = "obs_to_nvidia.lua";

    string? rootArg = null;
    string? copyTo = null;
    bool check = true, publish = false, yes = false, bump = true;
    for (int i = 0; i < args.Length; i++)
    {
        if (args[i] == "--copy-to" && i + 1 < args.Length) copyTo = args[++i];
        else if (args[i] == "--no-check") check = false;
        else if (args[i] == "--publish") publish = true;
        else if (args[i] == "--yes") yes = true;
        else if (args[i] == "--no-bump") bump = false;
        else if (rootArg is null) rootArg = args[i];
    }

    string? root = FindRoot(rootArg);
    if (root is null)
    {
        Console.Error.WriteLine("ERROR: could not find src\\_order.txt (run from the project folder or pass it as an argument).");
        return 1;
    }

    if (publish) PublishLog.Start(root);

    int rc = BuildBundle(root, out string outPath, out string version);
    if (rc != 0) return rc;

    if (check)
    {
        rc = SyntaxCheck(outPath);
        if (rc != 0) return rc; // a real syntax error: stop before copying/publishing anything
    }

    if (copyTo is not null)
    {
        Directory.CreateDirectory(copyTo);
        string dest = Path.Combine(copyTo, OutName);
        File.Copy(outPath, dest, overwrite: true);
        Console.WriteLine($"Copied to {dest}");
    }

    if (publish) return Publish(root, check, yes, bump);
    return 0;
}

// Reads _order.txt and returns the part file names in order.
static List<string> ReadParts(string root) =>
    File.ReadAllLines(Path.Combine(root, "src", "_order.txt"))
        .Select(l => l.Trim())
        .Where(l => l.Length > 0 && !l.StartsWith('#'))
        .ToList();

// Joins the parts into dist\obs_to_nvidia.lua. Returns 0 on success.
static int BuildBundle(string root, out string outPath, out string version)
{
    const string OutName = "obs_to_nvidia.lua";
    outPath = Path.Combine(root, "dist", OutName);
    version = "";

    string srcDir = Path.Combine(root, "src");
    var sb = new StringBuilder();
    int total = 0;
    foreach (var name in ReadParts(root))
    {
        string path = Path.Combine(srcDir, name);
        if (!File.Exists(path))
        {
            Console.Error.WriteLine($"ERROR: missing part listed in _order.txt: {name}");
            return 1;
        }

        // ReadAllText drops a UTF-8 BOM; a BOM in the middle of the output would break Lua.
        string text = File.ReadAllText(path, Encoding.UTF8).Replace("\r\n", "\n");
        if (!text.EndsWith('\n')) text += "\n";

        int lines = text.Count(c => c == '\n');
        total += lines;
        Console.WriteLine($"  {name,-28} {lines,6} lines");
        sb.Append(text);
    }

    string output = sb.ToString();

    // Sanity checks: the things OBS and the Updater rely on.
    foreach (var must in new[] { "function script_properties", "function script_load", "function script_unload", "local VERSION" })
    {
        if (!output.Contains(must))
        {
            Console.Error.WriteLine($"ERROR: output is missing \"{must}\" - check the part order/files.");
            return 1;
        }
    }

    Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
    File.WriteAllText(outPath, output, new UTF8Encoding(false)); // UTF-8, no BOM, LF

    var m = Regex.Match(output, Consts.VersionPattern);
    version = m.Success ? m.Groups[2].Value : "";
    Console.WriteLine($"Built {outPath}");
    Console.WriteLine($"  {total} lines, VERSION = {(version.Length > 0 ? version : "?")}");
    return 0;
}

// 2.5 -> 2.6, 2.5.3 -> 2.5.4 (the last number goes up by one). Returns null if not numeric.
static string? NextVersion(string v)
{
    var p = v.Split('.');
    if (p.Length == 0 || p.Any(x => !int.TryParse(x, out _))) return null;
    p[^1] = (int.Parse(p[^1]) + 1).ToString();
    return string.Join('.', p);
}

// One-click release: bump VERSION, build, commit + push the sources, then create a GitHub Release
// with dist\obs_to_nvidia.lua attached (this is what the in-OBS Update Checker downloads).
// Needs: git (repo with an "origin" on GitHub) and GitHub CLI (gh, logged in).
static int Publish(string root, bool check, bool yes, bool bump)
{
    Console.WriteLine();
    Console.WriteLine("=== Publish ===");

    if (Run("git", "rev-parse --is-inside-work-tree", root, quiet: true) != 0)
    { Console.Error.WriteLine("ERROR: this folder is not a git repository (or git is not installed). See README.md > First-time setup."); return 1; }
    if (Run("gh", "--version", root, quiet: true) != 0)
    { Console.Error.WriteLine("ERROR: GitHub CLI (gh) not found. Install it:  winget install GitHub.cli   then run:  gh auth login"); return 1; }
    if (Run("gh", "auth status", root, quiet: true) != 0)
    { Console.Error.WriteLine("ERROR: gh is not logged in. Run once in a terminal:  gh auth login"); return 1; }

    // Tell gh the repo explicitly, so it never needs to run git itself.
    string repoArg = RepoSlug(root) is string slug ? $" --repo {slug}" : "";

    // Find the file that holds VERSION and work out the version to release.
    string srcDir = Path.Combine(root, "src");
    string? verFile = ReadParts(root).Select(n => Path.Combine(srcDir, n))
        .FirstOrDefault(f => File.Exists(f) && Regex.IsMatch(File.ReadAllText(f, Encoding.UTF8), Consts.VersionPattern));
    if (verFile is null) { Console.Error.WriteLine("ERROR: could not find `local VERSION = \"...\"` in src."); return 1; }

    string originalText = File.ReadAllText(verFile, Encoding.UTF8);
    string current = Regex.Match(originalText, Consts.VersionPattern).Groups[2].Value;
    string next = current;
    if (bump)
    {
        string? n = NextVersion(current);
        if (n is null) { Console.Error.WriteLine($"ERROR: VERSION \"{current}\" is not numeric (like 2.5 or 2.5.1), cannot auto-bump. Use --no-bump."); return 1; }
        next = n;
    }
    // Self-healing: if the current VERSION was already committed/pushed but its GitHub release
    // was never created (an earlier run failed at the release step), release THAT version
    // instead of bumping again.
    if (bump && Run("gh", $"release view v{current}{repoArg}", root, quiet: true) != 0)
    {
        Console.WriteLine($"v{current} has no GitHub release yet - publishing it without bumping.");
        bump = false;
        next = current;
    }
    string tag = "v" + next;

    if (Run("gh", $"release view {tag}{repoArg}", root, quiet: true) == 0)
    {
        Console.Error.WriteLine($"ERROR: release {tag} already exists on GitHub. Set VERSION in {Path.GetFileName(verFile)} to the latest published version and run again.");
        return 1;
    }

    if (!yes)
    {
        Console.Write(bump
            ? $"Publish v{current} -> {tag} to GitHub for ALL users? Type y to continue: "
            : $"Publish {tag} to GitHub for ALL users? Type y to continue: ");
        var a = Console.ReadLine();
        if (!string.Equals(a?.Trim(), "y", StringComparison.OrdinalIgnoreCase)) { Console.WriteLine("Cancelled."); return 2; }
    }

    // From here on VERSION may change on disk; any failure puts the original text back.
    bool pushed = false;
    int Fail(string msg)
    {
        Console.Error.WriteLine("ERROR: " + msg);
        if (pushed) return 1; // the pushed commit already holds the new VERSION - keep it; the next run finishes the release
        File.WriteAllText(verFile, originalText, new UTF8Encoding(false));
        if (bump) Console.Error.WriteLine($"VERSION restored to {current}.");
        return 1;
    }

    if (bump)
    {
        string bumped = Regex.Replace(originalText, Consts.VersionPattern, $"${{1}}{next}${{3}}", RegexOptions.None, TimeSpan.FromSeconds(2));
        File.WriteAllText(verFile, bumped, new UTF8Encoding(false));
        Console.WriteLine($"VERSION: {current} -> {next}");
    }

    if (BuildBundle(root, out string outPath, out string built) != 0) return Fail("build failed.");
    if (built != next) return Fail($"built VERSION \"{built}\" does not match {next}.");
    if (check && SyntaxCheck(outPath) != 0) return Fail("syntax check failed.");

    EnsureIgnored(root, "publish.log");
    EnsureIgnored(root, "*.zip");
    if (Run("git", "add -A", root) != 0) return Fail("git add failed.");
    if (Run("git", "diff --cached --quiet", root, quiet: true) != 0) // there is something to commit
    {
        if (Run("git", $"commit -m \"Release {tag}\"", root) != 0) return Fail("git commit failed.");
    }
    else Console.WriteLine("Nothing new to commit.");
    if (Run("git", "push -u origin HEAD", root) != 0) return Fail("git push failed.");
    pushed = true;

    if (Run("gh", $"release create {tag} \"{outPath}\" --title \"{tag}\" --generate-notes{repoArg}", root) != 0)
        return Fail("creating the GitHub release failed (the code is already pushed - just press Release again, it will finish this version).");

    Console.WriteLine($"DONE - {tag} is published. OBS users will be offered the update.");
    return 0;
}

// Runs a command; returns its exit code, or -1 if the program cannot be started.
// Output is always captured (so no console window ever opens) and echoed unless quiet.
static int Run(string exe, string args, string workDir, bool quiet = false)
{
    exe = ResolveExe(exe);
    try
    {
        var psi = new System.Diagnostics.ProcessStartInfo(exe, args)
        {
            WorkingDirectory = workDir,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        // gh itself launches git, so git's and gh's folders must be on the PATH it inherits
        // (Visual Studio's PATH can be stale and miss them).
        var extra = new List<string>();
        foreach (var tool in new[] { "git", "gh" })
        {
            string r = ResolveExe(tool);
            string? d = Path.IsPathRooted(r) ? Path.GetDirectoryName(r) : null;
            if (d is not null) extra.Add(d);
        }
        psi.Environment["PATH"] = string.Join(';', extra) + ";" + (Environment.GetEnvironmentVariable("PATH") ?? "");
        psi.Environment["GIT_TERMINAL_PROMPT"] = "0"; // fail instead of waiting for typing
        psi.Environment["GH_PROMPT_DISABLED"] = "1";
        using var proc = System.Diagnostics.Process.Start(psi)!;
        var o = proc.StandardOutput.ReadToEndAsync();
        var e = proc.StandardError.ReadToEndAsync();
        proc.WaitForExit();
        string so = o.Result, se = e.Result;
        if (!quiet)
        {
            if (so.Length > 0) Console.Write(so);
            if (se.Length > 0) Console.Error.Write(se);
        }
        return proc.ExitCode;
    }
    catch (System.ComponentModel.Win32Exception)
    {
        return -1;
    }
}

// "owner/name" from the origin URL in .git/config, or null.
static string? RepoSlug(string root)
{
    try
    {
        string cfg = File.ReadAllText(Path.Combine(root, ".git", "config"));
        var m = Regex.Match(cfg, @"\[remote ""origin""\][^\[]*?url\s*=\s*\S*github\.com[:/]([^/\s]+)/([^\s]+?)(\.git)?\s*(\n|$)");
        return m.Success ? m.Groups[1].Value + "/" + m.Groups[2].Value : null;
    }
    catch { return null; }
}

// Makes sure the log file never gets committed by "git add -A".
static void EnsureIgnored(string root, string entry)
{
    string gi = Path.Combine(root, ".gitignore");
    string text = File.Exists(gi) ? File.ReadAllText(gi) : "";
    if (text.Split('\n').Any(l => l.Trim() == entry)) return;
    if (text.Length > 0 && !text.EndsWith('\n')) text += "\n";
    File.WriteAllText(gi, text + entry + "\n", new UTF8Encoding(false));
}

// Visual Studio only sees the PATH from when it was started, so a freshly installed tool
// (gh, git) can be "not found". Look in the default install folders first.
static string ResolveExe(string exe)
{
    var candidates = new List<string>();
    string pf = Environment.GetEnvironmentVariable("ProgramFiles") ?? @"C:\Program Files";
    string local = Environment.GetEnvironmentVariable("LOCALAPPDATA") ?? "";
    if (exe == "gh")
    {
        candidates.Add(Path.Combine(pf, "GitHub CLI", "gh.exe"));
        if (local.Length > 0) candidates.Add(Path.Combine(local, "Programs", "GitHub CLI", "gh.exe"));
    }
    else if (exe == "git")
    {
        candidates.Add(Path.Combine(pf, "Git", "cmd", "git.exe"));
        if (local.Length > 0) candidates.Add(Path.Combine(local, "Programs", "Git", "cmd", "git.exe"));
    }
    foreach (var c in candidates)
        if (File.Exists(c)) return c;
    foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
    {
        try { string f = Path.Combine(dir.Trim('"'), exe + ".exe"); if (File.Exists(f)) return f; } catch { }
    }
    return exe;
}

static string? FindRoot(string? hint)
{
    var starts = new List<string>();
    if (hint is not null) starts.Add(Path.GetFullPath(hint));
    starts.Add(Directory.GetCurrentDirectory());
    starts.Add(AppContext.BaseDirectory);

    foreach (var s in starts)
    {
        for (var d = new DirectoryInfo(s); d is not null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "src", "_order.txt")))
                return d.FullName;
    }
    return null;
}

// Optional Lua syntax check. Uses luac / luajit if one is on PATH; otherwise it is skipped.
// A syntax error is printed in MSBuild's "file : error CODE: text" format so Visual Studio
// shows it in the Error List and fails the build before the file ever reaches OBS.
static int SyntaxCheck(string luaFile)
{
    var candidates = new (string exe, string args)[]
    {
        ("luac",     $"-p \"{luaFile}\""),
        ("luac5.1",  $"-p \"{luaFile}\""),
        ("luac5.4",  $"-p \"{luaFile}\""),
        ("luajit",   $"-bl \"{luaFile}\""),
    };

    foreach (var (exe, a) in candidates)
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo(exe, a)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var proc = System.Diagnostics.Process.Start(psi)!;
            var outTask = proc.StandardOutput.ReadToEndAsync(); // drain (luajit -bl prints a lot)
            string err = proc.StandardError.ReadToEnd();
            proc.WaitForExit();
            outTask.Wait();

            if (proc.ExitCode == 0)
            {
                Console.WriteLine($"Syntax check OK ({exe}).");
                return 0;
            }
            Console.Error.WriteLine($"{luaFile} : error LUA001: syntax error ({exe}): {err.Trim().Replace('\n', ' ')}");
            return 1;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // this checker is not installed - try the next one
        }
    }

    Console.WriteLine("Syntax check skipped (no luac/luajit on PATH).");
    return 0;
}

static class Consts
{
    // Matches:  local VERSION = "2.5"   (group 2 = the version text)
    public const string VersionPattern = "(local\\s+VERSION\\s*=\\s*\")([^\"]+)(\")";
}

// In publish mode all Console output goes to publish.log, the VS Output window, and a buffer.
static class PublishLog
{
    static readonly StringBuilder Buf = new();

    public static void Start(string root)
    {
        var w = new LogWriter(Path.Combine(root, "publish.log"));
        Console.SetOut(w);
        Console.SetError(w);
    }

    public static string Tail()
    {
        lock (Buf)
        {
            string t = Buf.ToString().Trim();
            if (t.Length == 0) return "Publish failed. See publish.log in the project folder.";
            return (t.Length > 1500 ? "..." + t[^1500..] : t) + "\n\n(full log: publish.log)";
        }
    }

    sealed class LogWriter : TextWriter
    {
        readonly string _path;
        readonly StringBuilder _line = new();

        public LogWriter(string path)
        {
            _path = path;
            try { File.WriteAllText(_path, ""); } catch { }
        }

        public override Encoding Encoding => Encoding.UTF8;

        public override void Write(char c)
        {
            if (c == '\r') return;
            if (c == '\n') { Emit(); return; }
            _line.Append(c);
        }

        public override void Flush() { if (_line.Length > 0) Emit(); }

        void Emit()
        {
            string l = _line.ToString();
            _line.Clear();
            lock (Buf) Buf.AppendLine(l);
            System.Diagnostics.Trace.WriteLine(l); // shows in the Visual Studio Output window
            try { File.AppendAllText(_path, l + "\n"); } catch { }
        }
    }
}

static class NativeMethods
{
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

    public static void Show(string caption, string text)
    {
        try { MessageBoxW(IntPtr.Zero, text, caption, 0x10 | 0x40000); } // error icon, topmost
        catch { }
    }
}
