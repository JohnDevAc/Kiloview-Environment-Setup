// Copyright (c) 2026 John Lightfoot
// SPDX-License-Identifier: MIT
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace KiloLink.Setup
{
    // The NDI package has an unconditional [Run] launcher and console helpers.
    // STARTUPINFO's desktop is inherited by its children. Never switch to this
    // desktop. A private job owns only this installation and removes its leftover
    // completion launcher when setup exits, leaving existing NDI apps untouched.
    public sealed class QuietInstaller : IDisposable
    {
        private IntPtr desktop, job, process;
        private QuietInstaller() { }

        // Query only: never let an unattended vendor installer shut down other
        // applications or discover a locked DLL after uninstalling old Tools.
        public static string[] GetLockingApplications(string[] paths)
        {
            if (paths == null || paths.Length == 0) { return new string[0]; }
            uint session;
            int result = RmStartSession(out session, 0, new StringBuilder(33));
            if (result != 0) { throw new Win32Exception(result); }
            try
            {
                result = RmRegisterResources(session, (uint)paths.Length, paths, 0, IntPtr.Zero, 0, null);
                if (result != 0) { throw new Win32Exception(result); }
                uint needed, count = 0, reasons;
                RestartProcessInfo[] applications = null;
                for (int attempt = 0; attempt < 4; attempt++)
                {
                    result = RmGetList(session, out needed, ref count, applications, out reasons);
                    if (result == 0)
                    {
                        string[] names = new string[count];
                        for (int index = 0; index < count; index++)
                        {
                            names[index] = applications[index].Name + " (PID " + applications[index].Process.ProcessId + ")";
                        }
                        return names;
                    }
                    if (result != 234) { throw new Win32Exception(result); }
                    applications = new RestartProcessInfo[needed];
                    count = needed;
                }
                throw new InvalidOperationException("The applications using NDI files kept changing. Close NDI applications and retry.");
            }
            finally { RmEndSession(session); }
        }

        public static QuietInstaller Start(string path, string arguments)
        {
            QuietInstaller instance = new QuietInstaller();
            ProcessInformation child = new ProcessInformation();
            try
            {
                string name = "KiloviewSetup_" + Guid.NewGuid().ToString("N");
                instance.desktop = CreateDesktop(name, null, IntPtr.Zero, 0, 0x01FF, IntPtr.Zero);
                if (instance.desktop == IntPtr.Zero) { throw new Win32Exception(); }
                instance.job = CreateJobObject(IntPtr.Zero, null);
                if (instance.job == IntPtr.Zero) { throw new Win32Exception(); }
                ExtendedLimitInformation limits = new ExtendedLimitInformation();
                limits.BasicLimitInformation.LimitFlags = 0x2000; // KILL_ON_JOB_CLOSE
                if (!SetInformationJobObject(instance.job, 9, ref limits, (uint)Marshal.SizeOf(limits))) { throw new Win32Exception(); }
                StartupInformation startup = new StartupInformation();
                startup.cb = Marshal.SizeOf(startup);
                startup.lpDesktop = name;
                startup.dwFlags = 1; // STARTF_USESHOWWINDOW
                startup.wShowWindow = 0; // SW_HIDE
                if (!CreateProcess(path, new StringBuilder("\"" + path + "\" " + arguments), IntPtr.Zero, IntPtr.Zero,
                    false, 0x08000004, IntPtr.Zero, Path.GetDirectoryName(path), ref startup, out child)) { throw new Win32Exception(); }
                instance.process = child.hProcess;
                // Assign while suspended so no descendant can escape the job.
                if (!AssignProcessToJobObject(instance.job, child.hProcess)) { throw new Win32Exception(); }
                if (ResumeThread(child.hThread) == UInt32.MaxValue) { throw new Win32Exception(); }
                return instance;
            }
            catch
            {
                if (child.hProcess != IntPtr.Zero) { TerminateProcess(child.hProcess, 1); }
                instance.Dispose();
                throw;
            }
            finally { if (child.hThread != IntPtr.Zero) { CloseHandle(child.hThread); } }
        }

        public bool HasExited
        {
            get
            {
                uint status = WaitForSingleObject(process, 0);
                if (status == UInt32.MaxValue) { throw new Win32Exception(); }
                return status == 0;
            }
        }
        public int ExitCode
        {
            get
            {
                if (!HasExited) { throw new InvalidOperationException("The installer is still running."); }
                uint code;
                if (!GetExitCodeProcess(process, out code)) { throw new Win32Exception(); }
                return unchecked((int)code);
            }
        }
        public void Refresh() { }
        public void Dispose()
        {
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (process != IntPtr.Zero) { CloseHandle(process); process = IntPtr.Zero; }
            if (desktop != IntPtr.Zero) { CloseDesktop(desktop); desktop = IntPtr.Zero; }
            GC.SuppressFinalize(this);
        }
        ~QuietInstaller() { Dispose(); }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInformation
        {
            public int cb;
            public string lpReserved, lpDesktop, lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters { public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct RestartUniqueProcess
        {
            public uint ProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME StartTime;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RestartProcessInfo
        {
            public RestartUniqueProcess Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string ServiceName;
            public uint Type, Status, SessionId;
            [MarshalAs(UnmanagedType.Bool)] public bool Restartable;
        }
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint session, uint flags, StringBuilder key);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(uint session, uint fileCount, string[] files, uint processCount, IntPtr processes, uint serviceCount, string[] services);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmGetList(uint session, out uint needed, ref uint count, [In, Out] RestartProcessInfo[] applications, out uint reasons);
        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint session);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateDesktop(string name, string device, IntPtr mode, uint flags, uint access, IntPtr attributes);
        [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref ExtendedLimitInformation info, uint length);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes,
            bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInformation startup, out ProcessInformation process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll")] private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    }
}
