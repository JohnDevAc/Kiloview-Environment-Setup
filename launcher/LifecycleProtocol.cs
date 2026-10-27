// Copyright (c) 2026 John Lightfoot. SPDX-License-Identifier: MIT
// Shared by the native host and the generated PowerShell engine.
using System;
using System.Collections.Generic;
using System.IO;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Web.Script.Serialization;

namespace KiloLink.Lifecycle
{
    public static class AtomicFile
    {
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle file,int informationClass,IntPtr information,uint size);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);

        private static bool DeleteSharingConflict(string path)
        {
            // Rename-over-existing can report ACCESS_DENIED for an open target
            // which lacks FILE_SHARE_DELETE. Retry only when a DELETE-access
            // probe confirms sharing, not for ACL or read-only failures.
            using(SafeFileHandle handle=CreateFile(path,0x10000,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)) {
                int error=Marshal.GetLastWin32Error();
                return handle.IsInvalid && (error==32 || error==33);
            }
        }

        private static void RenameOverExisting(string temporary,string target)
        {
            using(SafeFileHandle handle=CreateFile(temporary,0x10000,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)) {
                if(handle.IsInvalid){ThrowRenameError(Marshal.GetLastWin32Error());}
                byte[] name=Encoding.Unicode.GetBytes(target);
                int rootOffset=IntPtr.Size, lengthOffset=rootOffset+IntPtr.Size, nameOffset=lengthOffset+4;
                int bufferSize=nameOffset+name.Length+IntPtr.Size;
                IntPtr buffer=Marshal.AllocHGlobal(bufferSize);
                try {
                    // Include the trailing WCHAR and native structure padding;
                    // FileNameLength itself excludes that terminator.
                    for(int i=0;i<bufferSize;i++){Marshal.WriteByte(buffer,i,0);}
                    // FileRenameInfoEx: REPLACE_IF_EXISTS | POSIX_SEMANTICS.
                    // Existing cooperative reader handles keep their old complete
                    // snapshot; new opens see the replacement. No delete/copy gap.
                    Marshal.WriteInt32(buffer,0,3);
                    Marshal.WriteIntPtr(buffer,rootOffset,IntPtr.Zero);
                    Marshal.WriteInt32(buffer,lengthOffset,name.Length);
                    Marshal.Copy(name,0,IntPtr.Add(buffer,nameOffset),name.Length);
                    if(!SetFileInformationByHandle(handle,22,buffer,(uint)bufferSize)){ThrowRenameError(Marshal.GetLastWin32Error());}
                } finally {Marshal.FreeHGlobal(buffer);}
            }
        }

        private static void ThrowRenameError(int error) {
            throw new IOException("Atomic rename failed (Windows error "+error+"): "+new System.ComponentModel.Win32Exception(error).Message,
                unchecked((int)0x80070000)|error);
        }

        private sealed class WriterLease : IDisposable
        {
            private System.Threading.Mutex mutex;
            public WriterLease(System.Threading.Mutex value) { mutex=value; }
            public void Dispose() {
                System.Threading.Mutex value=System.Threading.Interlocked.Exchange(ref mutex,null);
                if(value!=null){try{value.ReleaseMutex();}finally{value.Dispose();}}
            }
        }

        public static IDisposable Acquire(string target)
        {
            string identity=Path.GetFullPath(target).ToUpperInvariant();
            string digest;
            using(System.Security.Cryptography.SHA256 hash=System.Security.Cryptography.SHA256.Create()) {
                digest=BitConverter.ToString(hash.ComputeHash(Encoding.Unicode.GetBytes(identity))).Replace("-","");
            }
            // Synchronize elevated/native/PowerShell writers across Windows sessions.
            MutexSecurity security=new MutexSecurity();security.SetAccessRuleProtection(true,false);
            foreach(SecurityIdentifier sid in new[]{WindowsIdentity.GetCurrent().User,new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null),new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null)}) {
                security.AddAccessRule(new MutexAccessRule(sid,MutexRights.FullControl,AccessControlType.Allow));
            }
            bool created;
            System.Threading.Mutex mutex=new System.Threading.Mutex(false,@"Global\Kiloview.AtomicFile."+digest,out created,security);
            bool acquired=false;
            try {
                try {acquired=mutex.WaitOne(5000);} catch(System.Threading.AbandonedMutexException){acquired=true;}
                if(!acquired){throw new IOException("Another writer still owns the atomic result commit after five seconds: "+target);}
                return new WriterLease(mutex);
            } catch {if(acquired){mutex.ReleaseMutex();}mutex.Dispose();throw;}
        }

        // Rename a flushed sibling over the old file in one filesystem operation.
        // ReplaceFile's ACL/stream merge can partially rename files on errors 1176/
        // 1177. Do not use that operation, delete/truncate the target, or copy it.
        public static void Commit(string temporary, string target, Action validate)
        {
            temporary=Path.GetFullPath(temporary);target=Path.GetFullPath(target);
            if(!String.Equals(Path.GetDirectoryName(temporary),Path.GetDirectoryName(target),StringComparison.OrdinalIgnoreCase)
                || String.Equals(temporary,target,StringComparison.OrdinalIgnoreCase)) {
                throw new InvalidDataException("Atomic replacement requires a distinct staged file in the destination directory.");
            }
            using(Acquire(target)) {
            System.Diagnostics.Stopwatch elapsed = System.Diagnostics.Stopwatch.StartNew();
            int delay = 25;
            while (true) {
                if (validate != null) { validate(); }
                SafePath.Check(temporary);SafePath.CheckParent(target);
                if(File.Exists(target)) {
                    // A staged file inherits the directory ACL. Preserve any
                    // stricter access ACL on the existing result before rename.
                    FileSecurity access=new FileSecurity();
                    access.SetSecurityDescriptorBinaryForm(File.GetAccessControl(target,AccessControlSections.Access).GetSecurityDescriptorBinaryForm(),AccessControlSections.Access);
                    File.SetAccessControl(temporary,access);
                }
                try {
                    RenameOverExisting(temporary,target);
                    return;
                } catch (IOException exception) {
                    int code = exception.HResult & 0xffff;
                    if (code != 32 && code != 33 && !(code==5 && (DeleteSharingConflict(target) || DeleteSharingConflict(temporary)))) { throw; }
                    if (elapsed.ElapsedMilliseconds >= 5000) {
                        throw new IOException("Could not atomically save " + target
                            + " because Windows kept reporting file sharing conflicts for five seconds. The previous file was retained. Inspect the operation journal and writer diagnostics before retrying.", exception);
                    }
                    System.Threading.Thread.Sleep(Math.Max(1, Math.Min(delay, (int)(5000 - elapsed.ElapsedMilliseconds))));
                    delay = Math.Min(250, delay * 2);
                }
            }
            }
        }
    }

    public static class ConfigurationMsi
    {
        [DllImport("msi.dll",CharSet=CharSet.Unicode)] private static extern uint MsiEnumRelatedProducts(string upgrade,uint reserved,uint index,StringBuilder product);
        [DllImport("msi.dll",CharSet=CharSet.Unicode)] private static extern int MsiQueryProductState(string product);
        public static string[] InstalledProducts() {
            List<string> products=new List<string>();
            for(uint index=0;;index++) {
                StringBuilder product=new StringBuilder(39);uint code=MsiEnumRelatedProducts("{EB15F79D-6598-4AB1-8E39-B8D927B05862}",0,index,product);
                if(code==259){break;}if(code!=0){throw new System.ComponentModel.Win32Exception((int)code);}
                if(MsiQueryProductState(product.ToString())==5){products.Add(product.ToString());}
            }
            return products.ToArray();
        }
    }

    public static class SafePath
    {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool DeviceIoControl(SafeFileHandle file,uint code,IntPtr input,int inputSize,byte[] output,int outputSize,out int returned,IntPtr overlap);
        [StructLayout(LayoutKind.Sequential)] private struct FileInfo {
            internal uint Attributes;internal System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
            internal uint VolumeSerial,SizeHigh,SizeLow,Links,IdHigh,IdLow;
        }
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetFileInformationByHandle(SafeFileHandle file,out FileInfo info);
        public static bool IsAllowedCloudTag(uint tag) { return (tag & 0xffff0fffU) == 0x9000001aU; }
        public static void CheckParent(string path) {
            path=Path.GetFullPath(path);
            while(!Directory.Exists(path) && !File.Exists(path)){path=Path.GetDirectoryName(path);if(String.IsNullOrEmpty(path)){throw new InvalidDataException("No existing parent directory.");}}
            Check(path);
        }
        public static void Check(string path)
        {
            path=Path.GetFullPath(path);
            while(!String.IsNullOrEmpty(path)) {
                FileAttributes attributes=File.GetAttributes(path);
                if((attributes & FileAttributes.Directory)==0) {
                    using(SafeFileHandle handle=CreateFile(path,0,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)) {
                        FileInfo info;
                        if(handle.IsInvalid || !GetFileInformationByHandle(handle,out info) || info.Links!=1){throw new InvalidDataException("Lifecycle/maintenance files cannot have multiple hard links: "+path);}
                    }
                }
                if ((attributes & FileAttributes.ReparsePoint) != 0) {
                    using(SafeFileHandle handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
                        byte[] data=new byte[16384]; int count;
                        if(handle.IsInvalid || !DeviceIoControl(handle,0x900a8,IntPtr.Zero,0,data,data.Length,out count,IntPtr.Zero)
                            || count<8 || !IsAllowedCloudTag(BitConverter.ToUInt32(data,0))) {
                            throw new InvalidDataException("Path traverses an unsupported link or reparse point: " + path);
                        }
                    }
                }
                path=Path.GetDirectoryName(path);
            }
        }
    }

    public sealed class NativeProcess : IDisposable
    {
        private readonly System.Diagnostics.Process process;
        private readonly System.Collections.Concurrent.ConcurrentQueue<string> lines = new System.Collections.Concurrent.ConcurrentQueue<string>();
        private long lastOutput = DateTime.UtcNow.Ticks;
        public DateTime StartedUtc { get; private set; }
        public DateTime LastOutputUtc { get { return new DateTime(System.Threading.Interlocked.Read(ref lastOutput), DateTimeKind.Utc); } }
        public bool HasExited { get { return process.HasExited; } }
        public int ExitCode { get { process.WaitForExit(); return process.ExitCode; } }
        public int Id { get { return process.Id; } }
        public NativeProcess(string file, string[] arguments)
        {
            process = new System.Diagnostics.Process();
            List<string> quoted = new List<string>();
            foreach (string argument in arguments) { quoted.Add(Quote(argument)); }
            process.StartInfo = new System.Diagnostics.ProcessStartInfo(file, String.Join(" ", quoted)) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
            process.OutputDataReceived += Receive; process.ErrorDataReceived += Receive;
            if (!process.Start()) { throw new IOException("Windows did not start the requested command."); }
            StartedUtc = process.StartTime.ToUniversalTime(); process.StandardInput.Close();
            process.BeginOutputReadLine(); process.BeginErrorReadLine();
        }
        private void Receive(object sender, System.Diagnostics.DataReceivedEventArgs args) {
            if (args.Data != null) { lines.Enqueue(args.Data.Replace("\0", "")); System.Threading.Interlocked.Exchange(ref lastOutput, DateTime.UtcNow.Ticks); }
        }
        public string[] Drain() { List<string> result = new List<string>(); string line; while(lines.TryDequeue(out line)) { result.Add(line); } return result.ToArray(); }
        public void StopProbe() { if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); } }
        public void Dispose() { process.Dispose(); }
        public static string Quote(string value) {
            // WSL dispatches its leading switches from raw command-line tokens;
            // wrapping --install/--status in quotes prevents their recognition.
            // Quote only when needed, retaining Windows escaping for argument data.
            if (!String.IsNullOrEmpty(value)) {
                bool required = false;
                foreach(char c in value) { if (Char.IsWhiteSpace(c) || c == '"') { required = true; break; } }
                if (!required) { return value; }
            }
            StringBuilder result = new StringBuilder("\""); int slashes = 0;
            foreach(char c in value ?? "") {
                if(c == '\\') { slashes++; continue; }
                if(c == '"') { result.Append('\\', slashes * 2 + 1).Append(c); }
                else { result.Append('\\', slashes).Append(c); }
                slashes = 0;
            }
            return result.Append('\\', slashes * 2).Append('"').ToString();
        }
    }

    // The Windows inbox WSL bootstrap needs console handles. Keep this path
    // separate from redirected probes: it has a hidden console/private desktop
    // and a job assigned before its first instruction. A root exit is not a
    // completed operation while descendants remain. Closing our handles never
    // terminates servicing. An independent host retains this instance until the
    // tree exits and writes a durable completion receipt for later recovery.
    public sealed class ConsoleBootstrapProcess : IDisposable
    {
        private IntPtr desktop, job, process;
        public int Id { get; private set; }
        public DateTime StartedUtc { get; private set; }
        public string JobName { get; private set; }
        private const string JobPrefix = "Global\\KiloviewWslBootstrap_";

        public ConsoleBootstrapProcess(string file, string[] arguments, string jobName)
        {
            ValidateJobName(jobName);
            JobName = jobName;
            ProcessInformation child = new ProcessInformation();
            try {
                job = CreateJobObject(IntPtr.Zero, jobName);
                int error = Marshal.GetLastWin32Error();
                if (job == IntPtr.Zero) { throw new System.ComponentModel.Win32Exception(error); }
                if (error == 183) { throw new IOException("The bootstrap job already exists."); }
                string desktopName = "KiloviewWsl_" + Guid.NewGuid().ToString("N");
                desktop = CreateDesktop(desktopName, null, IntPtr.Zero, 0, 0x01FF, IntPtr.Zero);
                if (desktop == IntPtr.Zero) { throw new System.ComponentModel.Win32Exception(); }
                List<string> quoted = new List<string>();
                foreach (string argument in arguments) { quoted.Add(NativeProcess.Quote(argument)); }
                StartupInformation startup = new StartupInformation();
                startup.cb = Marshal.SizeOf(startup); startup.lpDesktop = desktopName;
                startup.dwFlags = 1; startup.wShowWindow = 0; // STARTF_USESHOWWINDOW / SW_HIDE
                // No STARTF_USESTDHANDLES: Windows supplies the new console's
                // input/output handles, rather than inheriting closed pipes.
                if (!CreateProcess(file, new StringBuilder(NativeProcess.Quote(file) + " " + String.Join(" ", quoted)),
                    IntPtr.Zero, IntPtr.Zero, false, 0x14, IntPtr.Zero, Path.GetDirectoryName(file), ref startup, out child)) {
                    throw new System.ComponentModel.Win32Exception();
                }
                process = child.hProcess; Id = unchecked((int)child.dwProcessId);
                if (!AssignProcessToJobObject(job, process)) { throw new System.ComponentModel.Win32Exception(); }
                long creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) { throw new System.ComponentModel.Win32Exception(); }
                StartedUtc = DateTime.FromFileTimeUtc(creation);
                if (ResumeThread(child.hThread) == UInt32.MaxValue) { throw new System.ComponentModel.Win32Exception(); }
            } catch {
                // Constructor failures occur before execution; only our suspended
                // child is terminated. Running servicing is never killed here.
                if (child.hProcess != IntPtr.Zero) { TerminateProcess(child.hProcess, 1); }
                Dispose(); throw;
            } finally { if (child.hThread != IntPtr.Zero) { CloseHandle(child.hThread); } }
        }
        private static void ValidateJobName(string name) {
            Guid id;
            if (name == null || !name.StartsWith(JobPrefix, StringComparison.Ordinal) ||
                !Guid.TryParseExact(name.Substring(JobPrefix.Length), "N", out id)) {
                throw new ArgumentException("Invalid bootstrap job name.");
            }
        }
        public static bool IsJobActive(string name) {
            ValidateJobName(name);
            IntPtr handle = OpenJobObject(4, false, name); // JOB_OBJECT_QUERY
            if (handle == IntPtr.Zero) {
                int error = Marshal.GetLastWin32Error();
                if (error == 2) { return false; }
                throw new System.ComponentModel.Win32Exception(error);
            }
            try { return ActiveCount(handle) != 0; } finally { CloseHandle(handle); }
        }
        private static uint ActiveCount(IntPtr handle) {
            AccountingInformation info;
            if (!QueryInformationJobObject(handle, 1, out info, (uint)Marshal.SizeOf(typeof(AccountingInformation)), IntPtr.Zero)) {
                throw new System.ComponentModel.Win32Exception();
            }
            return info.ActiveProcesses;
        }
        public bool HasExited { get {
            uint status = WaitForSingleObject(process, 0);
            if (status == UInt32.MaxValue) { throw new System.ComponentModel.Win32Exception(); }
            return status == 0 && ActiveCount(job) == 0;
        } }
        public int ExitCode { get {
            if (!HasExited) { throw new InvalidOperationException("The WSL bootstrap or a descendant is still running."); }
            uint code;
            if (!GetExitCodeProcess(process, out code)) { throw new System.ComponentModel.Win32Exception(); }
            return unchecked((int)code);
        } }
        public void Dispose() {
            if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
            // No KILL_ON_JOB_CLOSE: never kill servicing. The independent host
            // must keep this handle open until its process tree has completed.
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (desktop != IntPtr.Zero) { CloseDesktop(desktop); desktop = IntPtr.Zero; }
            GC.SuppressFinalize(this);
        }
        ~ConsoleBootstrapProcess() { Dispose(); }
        [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
        private struct StartupInformation {
            public int cb; public string lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
        [StructLayout(LayoutKind.Sequential)]
        private struct AccountingInformation {
            public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
        }
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr CreateJobObject(IntPtr attributes,string name);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr OpenJobObject(uint access,bool inherit,string name);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool QueryInformationJobObject(IntPtr job,int kind,out AccountingInformation info,uint size,IntPtr length);
        [DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern IntPtr CreateDesktop(string name,string device,IntPtr mode,uint flags,uint access,IntPtr attributes);
        [DllImport("user32.dll",SetLastError=true)] private static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] private static extern bool CreateProcess(string app,StringBuilder command,IntPtr processAttributes,IntPtr threadAttributes,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInformation startup,out ProcessInformation process);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool TerminateProcess(IntPtr process,uint code);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetProcessTimes(IntPtr process,out long creation,out long exit,out long kernel,out long user);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool GetExitCodeProcess(IntPtr process,out uint code);
        [DllImport("kernel32.dll",SetLastError=true)] private static extern bool CloseHandle(IntPtr handle);
    }

    public sealed class Request
    {
        public string RequestPath { get; private set; }
        public string DirectoryPath { get; private set; }
        public string ResultPath { get; private set; }
        public string OperationId { get; private set; }
        public string ProductId { get; private set; }
        public string Action { get; private set; }
        public string Role { get; private set; }
        public bool PreserveData { get; private set; }
        public string RequestedVersion { get; private set; }
        public string OwnerSid { get; private set; }
        public int Attempt { get; private set; }
        public static readonly string[] Actions = { "inspect", "install", "update", "repair", "uninstall", "remove-role", "remove-app", "backup", "maintain-runtime" };
        private static readonly string[] Outcomes = { "running", "succeeded", "no-change", "cancelled", "partial", "failed", "blocked", "restart-required" };
        private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 1024 * 1024 };

        public static Request Load(string path)
        { return LoadForProduct(path,"environment"); }

        public static Request LoadForProduct(string path,string productId)
        {
            if(productId!="environment" && productId!="pc-agent") {throw new InvalidDataException("Unsupported product identity.");}
            Request value = new Request();
            value.ProductId=productId;
            value.OwnerSid = WindowsIdentity.GetCurrent().User.Value;
            value.RequestPath = FullLocalPath(path);
            value.DirectoryPath = Path.GetDirectoryName(value.RequestPath);
            value.ValidateDirectory();
            ValidateFile(value.RequestPath, value.OwnerSid, true);
            if (new FileInfo(value.RequestPath).Length > 65536) { throw new InvalidDataException("Lifecycle request is too large."); }
            Dictionary<string, object> data = value.json.Deserialize<Dictionary<string, object>>(File.ReadAllText(value.RequestPath, Encoding.UTF8));
            Guid id;
            if (data == null || !IsSchemaOne(data) || Text(data, "productId") != productId
                || !Guid.TryParseExact(Text(data, "operationId"), "D", out id) || id == Guid.Empty
                || Array.IndexOf(Actions, Text(data, "action")) < 0)
            { throw new InvalidDataException("Unsupported or malformed Environment lifecycle request."); }
            value.OperationId = id.ToString("D");
            value.Action = Text(data, "action");
            value.Role = Text(data, "role");
            if (value.Role.Length != 0 && value.Role != "client" && value.Role != "server") { throw new InvalidDataException("Unsupported role."); }
            object preserve;
            value.PreserveData = true;
            if (data.TryGetValue("preserveData", out preserve)) {
                if (!(preserve is bool)) { throw new InvalidDataException("preserveData must be a boolean."); }
                value.PreserveData = (bool)preserve;
            }
            value.RequestedVersion = Text(data, "requestedVersion");
            value.ResultPath = FullLocalPath(Text(data, "resultPath"));
            if (!String.Equals(Path.GetDirectoryName(value.ResultPath), value.DirectoryPath, StringComparison.OrdinalIgnoreCase)
                || String.Equals(value.ResultPath, value.RequestPath, StringComparison.OrdinalIgnoreCase)
                || !String.Equals(Path.GetExtension(value.ResultPath), ".json", StringComparison.OrdinalIgnoreCase))
            { throw new InvalidDataException("Result must be a separate JSON file in the owned operation directory."); }
            value.Attempt = 1;
            Dictionary<string, object> previous = value.ReadResult();
            if (previous != null) { value.Attempt = Math.Max(1, Number(previous, "attempt")); }
            return value;
        }

        public static string FullLocalPath(string path)
        {
            if (String.IsNullOrWhiteSpace(path) || path.Length < 4 || !Char.IsLetter(path[0]) || path[1] != ':' || path[2] != '\\'
                || path.Substring(2).Contains(":") || path.IndexOfAny(new char[] { '\r', '\n', '\0', '"' }) >= 0)
            { throw new InvalidDataException("Lifecycle paths must be absolute local drive paths."); }
            foreach(string part in path.Substring(3).Split('\\')) {
                if(part.EndsWith(" ",StringComparison.Ordinal) || part.EndsWith(".",StringComparison.Ordinal) ||
                    System.Text.RegularExpressions.Regex.IsMatch(part,@"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$",System.Text.RegularExpressions.RegexOptions.IgnoreCase)) {
                    throw new InvalidDataException("Lifecycle paths cannot use ambiguous Windows names.");
                }
            }
            return Path.GetFullPath(path);
        }

        public void ValidateDirectory()
        {
            string path = DirectoryPath;
            if (!Directory.Exists(path)) { throw new DirectoryNotFoundException("Create the owned operation directory before invoking setup."); }
            SafePath.Check(path);
            ValidateAcl(Directory.GetAccessControl(DirectoryPath), OwnerSid);
        }

        private static void ValidateAcl(FileSystemSecurity security, string owner)
        {
            string actual = security.GetOwner(typeof(SecurityIdentifier)).Value;
            if (actual != owner && actual != "S-1-5-32-544") { throw new UnauthorizedAccessException("Lifecycle files must belong to the current Windows account."); }
            FileSystemRights write = FileSystemRights.Write | FileSystemRights.Delete | FileSystemRights.DeleteSubdirectoriesAndFiles | FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership;
            foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier))) {
                string sid = rule.IdentityReference.Value;
                if (rule.AccessControlType == AccessControlType.Allow && (rule.FileSystemRights & write) != 0
                    && sid != owner && sid != "S-1-5-18" && sid != "S-1-5-32-544" && sid != "S-1-3-0")
                { throw new UnauthorizedAccessException("Lifecycle directory or file permits writes by another account."); }
            }
        }

        private static void ValidateFile(string path, string owner, bool required)
        {
            if (!File.Exists(path)) { if (required) { throw new FileNotFoundException("Lifecycle request is missing.", path); } return; }
            SafePath.Check(path);
            if ((File.GetAttributes(path) & FileAttributes.Directory) != 0) { throw new InvalidDataException("Lifecycle file is a directory."); }
            ValidateAcl(File.GetAccessControl(path), owner);
        }

        public Dictionary<string, object> ReadResult()
        {
            // Validate and read the same published snapshot while cooperating
            // writers are excluded. An old reader handle can legitimately have
            // zero links after a POSIX replacement; do not weaken SafePath's
            // hard-link checks to accommodate that pathname-validation race.
            using(AtomicFile.Acquire(ResultPath)) {
            ValidateDirectory();
            if (!File.Exists(ResultPath)) { return null; }
            ValidateFile(ResultPath, OwnerSid, true);
            if (new FileInfo(ResultPath).Length > 1024 * 1024) { throw new InvalidDataException("Lifecycle result is too large."); }
            Dictionary<string, object> data;
            using (FileStream stream = new FileStream(ResultPath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete))
            using (StreamReader reader = new StreamReader(stream, Encoding.UTF8)) {
                data = json.Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
            }
            DateTime updated;
            if (data == null || !IsSchemaOne(data) || Text(data, "operationId") != OperationId
                || Text(data, "productId") != ProductId || Text(data, "action") != Action
                || Array.IndexOf(Outcomes, Text(data, "outcome")) < 0 || !data.ContainsKey("message")
                || !DateTime.TryParse(Text(data, "updatedUtc"), out updated))
            { throw new InvalidDataException("Stale or mismatched lifecycle result; refusing to overwrite it."); }
            return data;
            }
        }

        public void ContinueAttempt() { Attempt++; }

        public void Write(string outcome, string message, string stage, string errorCode, string nextAction, string extrasJson)
        {
            if (Array.IndexOf(Outcomes, outcome) < 0) { throw new InvalidDataException("Unsupported lifecycle outcome."); }
            using(AtomicFile.Acquire(ResultPath)) {
            ValidateDirectory();
            ReadResult();
            Dictionary<string, object> data = String.IsNullOrEmpty(extrasJson) ? new Dictionary<string, object>() : json.Deserialize<Dictionary<string, object>>(extrasJson);
            data["schemaVersion"] = 1; data["operationId"] = OperationId; data["productId"] = ProductId; data["action"] = Action;
            data["outcome"] = outcome; data["updatedUtc"] = DateTime.UtcNow.ToString("o"); data["message"] = message ?? "";
            data["attempt"] = Attempt; data["stage"] = stage ?? ""; data["errorCode"] = errorCode ?? ""; data["nextAction"] = nextAction ?? "";
            data["restartRequired"] = outcome == "restart-required";
            AtomicWrite(ResultPath, json.Serialize(data));
            }
        }

        public void AtomicWrite(string path, string text)
        {
            path = FullLocalPath(path);
            if (!String.Equals(Path.GetDirectoryName(path), DirectoryPath, StringComparison.OrdinalIgnoreCase) || String.Equals(path, RequestPath, StringComparison.OrdinalIgnoreCase)) { throw new InvalidDataException("Lifecycle output escaped its operation directory."); }
            using(AtomicFile.Acquire(path)) {
            ValidateDirectory(); ValidateFile(path, OwnerSid, false);
            string temporary = Path.Combine(DirectoryPath, ".write-" + Guid.NewGuid().ToString("N") + ".tmp");
            try {
                using (FileStream stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                    byte[] bytes = new UTF8Encoding(false).GetBytes(text); stream.Write(bytes, 0, bytes.Length); stream.Flush(true);
                }
                AtomicFile.Commit(temporary, path, delegate { ValidateDirectory(); ValidateFile(path, OwnerSid, false); });
            } finally { if (File.Exists(temporary)) { File.Delete(temporary); } }
            }
        }

        public static int ExitCode(string outcome, string errorCode)
        {
            if (outcome == "succeeded" || outcome == "no-change") { return 0; }
            if (outcome == "cancelled") { return 1602; }
            if (outcome == "restart-required") { return 3010; }
            if (errorCode == "operation-conflict") { return 1618; }
            return 1;
        }
        public static string Text(IDictionary<string, object> data, string key) { object value; return data != null && data.TryGetValue(key, out value) && value != null ? Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture) : ""; }
        public static int Number(IDictionary<string, object> data, string key) { int value; return Int32.TryParse(Text(data, key), out value) ? value : -1; }
        private static bool IsSchemaOne(IDictionary<string, object> data) { object value; return data.TryGetValue("schemaVersion", out value) && value is int && (int)value == 1; }
    }
}
