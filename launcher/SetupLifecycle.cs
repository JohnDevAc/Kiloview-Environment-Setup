// Copyright (c) 2026 John Lightfoot. SPDX-License-Identifier: MIT
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;
using KiloLink.Lifecycle;

namespace KiloLink.Setup
{
    internal static partial class SetupLauncher
    {
        internal static Request LifecycleRequest;
        internal static bool LifecycleWorkerStarted;
        internal static string LifecycleRequestHash;

        internal static string ReleaseVersion {
            get {
                Assembly assembly=Assembly.GetExecutingAssembly();
                object[] attributes=assembly.GetCustomAttributes(typeof(AssemblyInformationalVersionAttribute),false);
                return attributes.Length==1 ? ((AssemblyInformationalVersionAttribute)attributes[0]).InformationalVersion : assembly.GetName().Version.ToString(3);
            }
        }

        internal static void LoadLifecycle(string[] arguments)
        {
            for(int i=0;i<arguments.Length;i++) {
                if(arguments[i] != "--lifecycle-request") { continue; }
                if(LifecycleRequest != null || ++i == arguments.Length) { throw new InvalidDataException("Supply one lifecycle request path."); }
                LifecycleRequest=Request.Load(arguments[i]);
                LifecycleRequestHash=HashFile(LifecycleRequest.RequestPath);
            }
            if(LifecycleRequest == null) { return; }
            for(int i=0;i<arguments.Length;i++) {
                if(arguments[i]=="--lifecycle-sha256" && (++i==arguments.Length || arguments[i]!=LifecycleRequestHash)) {
                    throw new InvalidDataException("Lifecycle request changed during elevation.");
                }
            }
            string version=ReleaseVersion;
            if(LifecycleRequest.RequestedVersion.Length>0 && LifecycleRequest.RequestedVersion != version) {
                WriteLifecycle("blocked","This setup does not match the requested version.","preflight","version-mismatch");
                throw new InvalidDataException("Use the verified requested installer version.");
            }
        }

        internal static string HashFile(string path) {
            using(System.Security.Cryptography.SHA256 hash=System.Security.Cryptography.SHA256.Create()) {
                return BitConverter.ToString(hash.ComputeHash(File.ReadAllBytes(path))).Replace("-","");
            }
        }

        internal static void WriteLifecycle(string outcome,string message,string stage,string error)
        {
            if(LifecycleRequest == null) { return; }
            Dictionary<string,object> extras=LifecycleRequest.ReadResult() ?? new Dictionary<string,object>();
            extras["safeToCancel"]=!LifecycleWorkerStarted;
            LifecycleRequest.Write(outcome,message,stage,error,Request.Text(extras,"nextAction"),new JavaScriptSerializer().Serialize(extras));
        }

        internal static int InspectLifecycle()
        {
            Request request=LifecycleRequest;
            request.AtomicWrite(Path.Combine(request.DirectoryPath,"Install-KiloLinkSuite.ps1"),ReadEmbeddedText(InstallerResourceName));
            request.AtomicWrite(Path.Combine(request.DirectoryPath,"QuietInstaller.cs"),ReadEmbeddedText("KiloLink.Setup.QuietInstaller.cs"));
            string engine=Path.Combine(request.DirectoryPath,"Install-KiloLinkSuite.ps1");
            string shell=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),@"WindowsPowerShell\v1.0\powershell.exe");
            using(NativeProcess process=new NativeProcess(shell,new string[]{"-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-File",engine,"-LifecycleRequestPath",request.RequestPath})) {
                while(!process.HasExited) {
                    process.Drain();
                    if((DateTime.UtcNow-process.StartedUtc).TotalSeconds>120) {
                        process.StopProbe(); WriteLifecycle("blocked","Read-only inspection exceeded its deadline.","inspect","inspection-timeout"); return 1;
                    }
                    System.Threading.Thread.Sleep(100);
                }
                int code=process.ExitCode;
                Dictionary<string,object> result=request.ReadResult();
                if(result==null || Request.Text(result,"outcome")=="running") {
                    WriteLifecycle("failed","Inspection exited without a verified result.","inspect","missing-result"); return 1;
                }
                return code==0?Request.ExitCode(Request.Text(result,"outcome"),Request.Text(result,"errorCode")):code;
            }
        }
    }

    internal sealed partial class SetupForm
    {
        private bool lifecycleIntentRestored;
        private bool purgeConfirmed;
        private bool unattendedTimedOut;
        private DateTime packageStartedUtc;
        private DateTime packageHeartbeatUtc;

        private void CheckConfigurationPackageDeadline()
        {
            if(!configurationPackageInProgress || installerProcess==null || unattendedTimedOut || (DateTime.UtcNow-packageHeartbeatUtc).TotalSeconds<5){return;}
            packageHeartbeatUtc=DateTime.UtcNow;
            SetupLauncher.WriteLifecycle("running","Windows Installer is applying the configuration package.","configuration-package","");
            if((DateTime.UtcNow-packageStartedUtc).TotalMinutes<30){return;}
            string stateDirectory=Path.GetDirectoryName(launcherDirectory);
            SafePath.Check(stateDirectory);
            string path=Path.Combine(stateDirectory,"pending-process.json");
            if(File.Exists(path)){SafePath.Check(path);}
            string temporary=Path.Combine(stateDirectory,"pending-"+Guid.NewGuid().ToString("N")+".tmp");
            File.WriteAllText(temporary,eventSerializer.Serialize(new Dictionary<string,object>{
                {"processId",installerProcess.Id},{"startedUtc",installerProcess.StartTime.ToUniversalTime().ToString("o")},
                {"filePath",installerProcess.StartInfo.FileName},{"action",selectedAction},{"reason","Windows Installer exceeded 30 minutes; transaction was retained."}}));
            if(File.Exists(path)){File.Replace(temporary,path,null);}else{File.Move(temporary,path);}
            unattendedTimedOut=true;operationOutcome="Blocked";
            operationMessage="Windows Installer exceeded its time limit. Its transaction is still running and was retained. Wait for Windows Installer, inspect configuration-package.log, then verify the installation before retrying.";
            if(SetupLauncher.LifecycleRequest!=null){
                Dictionary<string,object> result=SetupLauncher.LifecycleRequest.ReadResult()??new Dictionary<string,object>();
                result["recoveryRequired"]=true;result["safeToCancel"]=false;
                SetupLauncher.LifecycleRequest.Write("blocked",operationMessage,"configuration-package","package-timeout",operationMessage,eventSerializer.Serialize(result));
            }
            activityLabel.Text="Windows Installer needs attention";progressStatusLabel.Text=operationMessage;
            finishButton.Enabled=true;finishButton.Text="Close";Environment.ExitCode=1;
        }

        private string LifecycleEngineAction()
        {
            Request request=SetupLauncher.LifecycleRequest;
            if(request==null) { return SetupLauncher.InitialAction.Length>0?SetupLauncher.InitialAction:"Setup"; }
            switch(request.Action) {
                case "uninstall":case "remove-role":return "Uninstall";
                case "remove-app":return "RemoveApp";
                case "backup":return "Backup";
                case "maintain-runtime":return "MaintainRuntime";
                case "update":return clientChoice.Checked?"InstallClient":"Update";
                case "repair":return clientChoice.Checked?"InstallClient":"Repair";
                default:return clientChoice.Checked?"InstallClient":"Setup";
            }
        }

        private void ShowLifecycleRequest()
        {
            Request request=SetupLauncher.LifecycleRequest;
            if(request==null || autoResume) { return; }
            SetupLauncher.WriteLifecycle("running","Review the requested operation in Environment Setup.","waiting-review","");
            if(request.Role.Length>0) { clientChoice.Checked=request.Role=="client";serverChoice.Checked=request.Role=="server";ChooseRole(); }
            else if(request.Action=="remove-app") {selectedAction="RemoveApp";ReviewSelectedAction();}
        }

        private string AddLifecycleArguments(string arguments)
        {
            Request request=SetupLauncher.LifecycleRequest;
            if(request==null) { return arguments+(clientChoice.Checked?" -Role client":" -Role server"); }
            request.ValidateDirectory();
            string role=clientChoice.Checked?"client":"server";
            if(!autoResume) {
                Dictionary<string,object> intent=new Dictionary<string,object> {
                    {"schemaVersion",1},{"operationId",request.OperationId},{"engineAction",selectedAction},{"role",role},
                    {"accepted",acceptanceBox.Checked},{"purgeData",purgeConfirmed},{"configurationPath",requestPath ?? ""},
                    {"requestHash",SetupLauncher.LifecycleRequestHash} };
                request.AtomicWrite(Path.Combine(request.DirectoryPath,"intent.json"),eventSerializer.Serialize(intent));
            }
            return arguments+" -Role "+role+" -LifecycleRequestPath "+SetupLauncher.Quote(request.RequestPath);
        }

        private void RestoreLifecycleIntent()
        {
            Request request=SetupLauncher.LifecycleRequest;
            if(request==null || !autoResume) { return; }
            string path=Path.Combine(request.DirectoryPath,"intent.json");
            SafePath.Check(path);
            Dictionary<string,object> intent=eventSerializer.Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
            if(Request.Text(intent,"operationId")!=request.OperationId || !intent.ContainsKey("accepted") || !(intent["accepted"] is bool) || !(bool)intent["accepted"])
                {throw new InvalidDataException("Reviewed continuation is missing or invalid. Reopen setup to review the operation.");}
            if(Request.Text(intent,"requestHash")!=SetupLauncher.LifecycleRequestHash){throw new InvalidDataException("The lifecycle request changed after review.");}
            string action=Request.Text(intent,"engineAction");
            if(Array.IndexOf(new string[]{"Setup","InstallClient","Update","Repair","MaintainRuntime","Backup","Uninstall","RemoveApp"},action)<0)
                {throw new InvalidDataException("Unsupported continuation action.");}
            clientChoice.Checked=Request.Text(intent,"role")=="client";serverChoice.Checked=!clientChoice.Checked;
            selectedAction=action;acceptanceBox.Checked=true;
            requestPath=Request.Text(intent,"configurationPath");
            if(requestPath.Length>0 && !String.Equals(Path.GetDirectoryName(Request.FullLocalPath(requestPath)),request.DirectoryPath,StringComparison.OrdinalIgnoreCase))
                {throw new InvalidDataException("Continuation configuration escaped its operation directory.");}
            lifecycleIntentRestored=true;
        }

        private void EnsureRetainedMaintenance()
        {
            string directory=Path.Combine(Path.GetDirectoryName(launcherDirectory),"Maintenance");
            SafePath.CheckParent(directory);Directory.CreateDirectory(directory);SafePath.Check(directory);
            DirectorySecurity security=new DirectorySecurity();security.SetAccessRuleProtection(true,false);
            SecurityIdentifier admins=new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null);
            security.SetOwner(admins);
            foreach(WellKnownSidType sid in new[]{WellKnownSidType.BuiltinAdministratorsSid,WellKnownSidType.LocalSystemSid}) {
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid,null),FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
            }
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid,null),FileSystemRights.ReadAndExecute,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
            Directory.SetAccessControl(directory,security);
            string target=Path.Combine(directory,"Kiloview-Environment-Setup.exe");
            string source=Assembly.GetExecutingAssembly().Location;
            foreach(string name in new[]{"Kiloview-Environment-Setup.exe","Install-KiloLinkSuite.ps1","QuietInstaller.cs","toolbox-lifecycle.json"}) {
                string file=Path.Combine(directory,name);if(File.Exists(file)){SafePath.Check(file);}
            }
            if(!String.Equals(source,target,StringComparison.OrdinalIgnoreCase)) {WriteMaintenanceFile(directory,"Kiloview-Environment-Setup.exe",File.ReadAllBytes(source));}
            else {
                FileSecurity existing=File.GetAccessControl(target);
                FileSystemRights writes=FileSystemRights.Write|FileSystemRights.Delete|FileSystemRights.ChangePermissions|FileSystemRights.TakeOwnership;
                foreach(FileSystemAccessRule rule in existing.GetAccessRules(true,true,typeof(SecurityIdentifier))){
                    if(rule.AccessControlType==AccessControlType.Allow && (rule.FileSystemRights&writes)!=0 && rule.IdentityReference.Value!="S-1-5-18" && rule.IdentityReference.Value!="S-1-5-32-544"){
                        throw new UnauthorizedAccessException("Retained maintenance has unexpected write permissions. Run the verified installer package to repair its files.");
                    }
                }
            }
            foreach(string name in new[]{"Install-KiloLinkSuite.ps1","QuietInstaller.cs"}) {
                using(Stream resource=Assembly.GetExecutingAssembly().GetManifestResourceStream("KiloLink.Setup."+name))
                using(MemoryStream buffer=new MemoryStream()){resource.CopyTo(buffer);WriteMaintenanceFile(directory,name,buffer.ToArray());}
            }
            WriteMaintenanceFile(directory,"toolbox-lifecycle.json",Encoding.UTF8.GetBytes(eventSerializer.Serialize(new Dictionary<string,object>{
                {"schemaVersion",1},{"productId","environment"},{"entryPoint","Kiloview-Environment-Setup.exe"},{"entryPointKind","native"},{"supportedActions",Request.Actions}})));
            if(SetupLauncher.HashFile(source)!=SetupLauncher.HashFile(target)){throw new InvalidDataException("Retained maintenance executable did not verify.");}
            persistentLauncherPath=target;
            installerPath=Path.Combine(directory,"Install-KiloLinkSuite.ps1");
        }

        private static void WriteMaintenanceFile(string directory,string name,byte[] bytes)
        {
            string target=Path.Combine(directory,name);if(File.Exists(target)){SafePath.Check(target);}
            string temporary=Path.Combine(directory,".stage-"+Guid.NewGuid().ToString("N"));
            try {
                using(FileStream stream=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None)){stream.Write(bytes,0,bytes.Length);stream.Flush(true);}
                FileSecurity security=new FileSecurity();security.SetAccessRuleProtection(true,false);
                security.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null));
                foreach(WellKnownSidType sid in new[]{WellKnownSidType.BuiltinAdministratorsSid,WellKnownSidType.LocalSystemSid}){
                    security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid,null),FileSystemRights.FullControl,AccessControlType.Allow));
                }
                security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid,null),FileSystemRights.ReadAndExecute,AccessControlType.Allow));
                File.SetAccessControl(temporary,security);
                if(File.Exists(target)){File.Replace(temporary,target,null);}else{File.Move(temporary,target);}
                File.SetAccessControl(target,security);
            } finally {if(File.Exists(temporary)){File.Delete(temporary);}}
        }

        private void CompleteLifecycle(int exitCode)
        {
            // Stdout outcome events precede the engine's durable write. Only the
            // actual worker-exit callback may reconcile its final result.
            if(SetupLauncher.LifecycleRequest==null || IsOperationInProgress) {return;}
            Dictionary<string,object> result=SetupLauncher.LifecycleRequest.ReadResult();
            if(result==null || Request.Text(result,"outcome")=="running") {
                SetupLauncher.WriteLifecycle(exitCode==3010?"restart-required":exitCode==1602?"cancelled":"failed",operationMessage,"worker-exit",exitCode==3010 || exitCode==1602?"":"missing-terminal-result");
            }
            result=SetupLauncher.LifecycleRequest.ReadResult();
            if(exitCode!=0 && (Request.Text(result,"outcome")=="succeeded" || Request.Text(result,"outcome")=="no-change")) {
                SetupLauncher.WriteLifecycle("failed","The deployment worker exited unsuccessfully after reporting completion.","worker-exit","exit-result-mismatch");
                result=SetupLauncher.LifecycleRequest.ReadResult();
            }
            Environment.ExitCode=Request.ExitCode(Request.Text(result,"outcome"),Request.Text(result,"errorCode"));
        }
    }
}
