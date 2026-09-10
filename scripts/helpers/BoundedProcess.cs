// Windows job ownership starts before any child code can execute. A job close
// also kills surviving descendants if the launcher is interrupted or crashes.
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Step1.Resources {
    public sealed class Result {
        public string LimitStatus = "not_started";
        public int ExitCode = 1;
        public int ProcessId;
        public double WallSeconds;
        public ulong PeakPrivateBytes;
        public ulong PeakWorkingSetBytes;
        public uint TotalProcesses;
        public string Error = "";
    }

    public static class BoundedProcess {
        const uint CREATE_SUSPENDED = 0x4, CREATE_NO_WINDOW = 0x08000000, CREATE_UNICODE_ENVIRONMENT = 0x400;
        const uint JOB_OBJECT_LIMIT_JOB_MEMORY = 0x200, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
        const uint JOB_OBJECT_MSG_JOB_MEMORY_LIMIT = 10, JOB_OBJECT_MSG_PROCESS_MEMORY_LIMIT = 9;
        [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
        [StructLayout(LayoutKind.Sequential)] struct BASIC_LIMIT {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] struct EXTENDED_LIMIT {
            public BASIC_LIMIT BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
        [StructLayout(LayoutKind.Sequential)] struct BASIC_ACCOUNTING {
            public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
            public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
        }
        [StructLayout(LayoutKind.Sequential)] struct COMPLETION_PORT { public IntPtr CompletionKey, CompletionPort; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct STARTUPINFO {
            public int cb; public string lpReserved, lpDesktop, lpTitle;
            public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }
        [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public uint dwProcessId, dwThreadId; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory, ref STARTUPINFO startup, out PROCESS_INFORMATION process);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateIoCompletionPort(IntPtr file, IntPtr port, IntPtr key, uint threads);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetQueuedCompletionStatus(IntPtr port, out uint code, out IntPtr key, out IntPtr overlapped, uint milliseconds);

        static Exception Error(string action) { return new Win32Exception(Marshal.GetLastWin32Error(), action); }
        static void SetInfo<T>(IntPtr job, int kind, T value) where T : struct {
            int size = Marshal.SizeOf(typeof(T)); IntPtr memory = Marshal.AllocHGlobal(size);
            try { Marshal.StructureToPtr(value, memory, false); if (!SetInformationJobObject(job, kind, memory, (uint)size)) throw Error("SetInformationJobObject"); }
            finally { Marshal.FreeHGlobal(memory); }
        }
        static T GetInfo<T>(IntPtr job, int kind) where T : struct {
            int size = Marshal.SizeOf(typeof(T)); IntPtr memory = Marshal.AllocHGlobal(size);
            try { if (!QueryInformationJobObject(job, kind, memory, (uint)size, IntPtr.Zero)) throw Error("QueryInformationJobObject"); return (T)Marshal.PtrToStructure(memory, typeof(T)); }
            finally { Marshal.FreeHGlobal(memory); }
        }
        static ulong WorkingSet(IntPtr job) {
            // Up to 4096 processes; a macro MATLAB run normally has fewer than ten.
            int bytes = 8 + 4096 * IntPtr.Size; IntPtr memory = Marshal.AllocHGlobal(bytes);
            try {
                if (!QueryInformationJobObject(job, 3, memory, (uint)bytes, IntPtr.Zero)) throw Error("Query job process IDs");
                int count = Marshal.ReadInt32(memory, 4); ulong total = 0;
                for (int i = 0; i < count; ++i) {
                    long id = Marshal.ReadIntPtr(memory, 8 + i * IntPtr.Size).ToInt64();
                    try { using (Process process = Process.GetProcessById((int)id)) { total += (ulong)process.WorkingSet64; } }
                    catch (ArgumentException) { } // An observed process exited before its sample.
                    catch (InvalidOperationException) { }
                    catch (Win32Exception) { }
                }
                return total;
            } finally { Marshal.FreeHGlobal(memory); }
        }
        public static string Quote(string value) {
            if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
            StringBuilder quoted = new StringBuilder("\""); int slashes = 0;
            foreach (char c in value) {
                if (c == '\\') { ++slashes; continue; }
                if (c == '"') { quoted.Append('\\', slashes * 2 + 1); quoted.Append(c); slashes = 0; continue; }
                quoted.Append('\\', slashes); slashes = 0; quoted.Append(c);
            }
            quoted.Append('\\', slashes * 2); quoted.Append('"'); return quoted.ToString();
        }
        public static Result Run(string executable, string[] arguments, string directory, double maxSeconds, ulong memoryLimitBytes, string[] environmentNames, string[] environmentValues) {
            Result result = new Result(); Stopwatch timer = Stopwatch.StartNew();
            IntPtr job = IntPtr.Zero, port = IntPtr.Zero, childEnvironment = IntPtr.Zero; PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            bool assigned = false;
            try {
                job = CreateJobObject(IntPtr.Zero, null); if (job == IntPtr.Zero) throw Error("CreateJobObject");
                EXTENDED_LIMIT limits = new EXTENDED_LIMIT();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_JOB_MEMORY;
                limits.JobMemoryLimit = (UIntPtr)memoryLimitBytes; SetInfo(job, 9, limits);
                port = CreateIoCompletionPort(new IntPtr(-1), IntPtr.Zero, IntPtr.Zero, 1);
                if (port == IntPtr.Zero) throw Error("CreateIoCompletionPort");
                COMPLETION_PORT completion = new COMPLETION_PORT(); completion.CompletionKey = job; completion.CompletionPort = port; SetInfo(job, 7, completion);
                StringBuilder command = new StringBuilder(Quote(executable));
                foreach (string argument in arguments) command.Append(" ").Append(Quote(argument));
                SortedDictionary<string, string> variables = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (DictionaryEntry variable in Environment.GetEnvironmentVariables()) variables[(string)variable.Key] = (string)variable.Value;
                for (int i = 0; i < environmentNames.Length; ++i) variables[environmentNames[i]] = environmentValues[i];
                StringBuilder environment = new StringBuilder();
                foreach (KeyValuePair<string, string> variable in variables) environment.Append(variable.Key).Append('=').Append(variable.Value).Append('\0');
                environment.Append('\0'); childEnvironment = Marshal.StringToHGlobalUni(environment.ToString());
                STARTUPINFO startup = new STARTUPINFO(); startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                startup.dwFlags = 1; startup.wShowWindow = 0; // STARTF_USESHOWWINDOW / SW_HIDE.
                if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, childEnvironment, directory, ref startup, out process)) throw Error("CreateProcess suspended");
                result.ProcessId = (int)process.dwProcessId;
                if (!AssignProcessToJobObject(job, process.hProcess)) throw Error("AssignProcessToJobObject (child remains suspended)");
                assigned = true;
                if (ResumeThread(process.hThread) == UInt32.MaxValue) throw Error("ResumeThread");
                result.LimitStatus = "running";
                while (true) {
                    uint code; IntPtr key, overlapped;
                    bool memoryExceeded = false;
                    while (GetQueuedCompletionStatus(port, out code, out key, out overlapped, 0)) {
                        if (code == JOB_OBJECT_MSG_JOB_MEMORY_LIMIT || code == JOB_OBJECT_MSG_PROCESS_MEMORY_LIMIT) memoryExceeded = true;
                    }
                    EXTENDED_LIMIT observed = GetInfo<EXTENDED_LIMIT>(job, 9);
                    result.PeakPrivateBytes = Math.Max(result.PeakPrivateBytes, observed.PeakJobMemoryUsed.ToUInt64());
                    // Completion-port hard-limit messages can be dropped by
                    // Windows. Never accept an observed over-budget run even
                    // if that notification did not arrive.
                    memoryExceeded = memoryExceeded || result.PeakPrivateBytes > memoryLimitBytes;
                    result.PeakWorkingSetBytes = Math.Max(result.PeakWorkingSetBytes, WorkingSet(job));
                    BASIC_ACCOUNTING accounting = GetInfo<BASIC_ACCOUNTING>(job, 1); result.TotalProcesses = accounting.TotalProcesses;
                    if (memoryExceeded) { result.LimitStatus = "memory_limit_exceeded"; result.ExitCode = 125; TerminateJobObject(job, 125); break; }
                    if (timer.Elapsed.TotalSeconds >= maxSeconds) { result.LimitStatus = "timeout"; result.ExitCode = 124; TerminateJobObject(job, 124); break; }
                    if (accounting.ActiveProcesses == 0) {
                        uint exitCode; if (!GetExitCodeProcess(process.hProcess, out exitCode)) throw Error("GetExitCodeProcess");
                        result.ExitCode = unchecked((int)exitCode); result.LimitStatus = exitCode == 0 ? "within_limits" : "process_failed"; break;
                    }
                    Thread.Sleep((int)Math.Max(1, Math.Min(100, (maxSeconds - timer.Elapsed.TotalSeconds) * 1000)));
                }
            } catch (Exception exception) {
                result.LimitStatus = "monitor_failed"; result.ExitCode = 126; result.Error = exception.Message;
                if (assigned && job != IntPtr.Zero) TerminateJobObject(job, 126);
                else if (process.hProcess != IntPtr.Zero) TerminateProcess(process.hProcess, 126);
            } finally {
                // Closing the owned job cannot affect an unrelated user MATLAB.
                if (job != IntPtr.Zero) CloseHandle(job);
                if (process.hProcess != IntPtr.Zero) { WaitForSingleObject(process.hProcess, 1000); CloseHandle(process.hProcess); }
                if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
                if (port != IntPtr.Zero) CloseHandle(port);
                if (childEnvironment != IntPtr.Zero) Marshal.FreeHGlobal(childEnvironment);
                result.WallSeconds = timer.Elapsed.TotalSeconds;
            }
            return result;
        }
    }
}
