using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Web.Script.Serialization;
using KiloLink.Lifecycle;

internal static class LifecycleConcurrencyFixture
{
    private static int Main(string[] args)
    {
        string mode=args[0], requestPath=args[1], reportPath=args[2];
        int count=0;List<string> errors=new List<string>();
        JavaScriptSerializer json=new JavaScriptSerializer();
        try {
            Request request=Request.Load(requestPath);
            if(mode=="writer") {
                for(int i=0;i<100;i++){request.Write("running","Writer "+Path.GetFileName(reportPath)+" item "+i,"fixture","","","{}");count++;}
            } else if(mode=="reader" || mode=="poller") {
                DateTime deadline=DateTime.UtcNow.AddSeconds(30);
                while(!File.Exists(Path.Combine(request.DirectoryPath,"stop.signal")) && DateTime.UtcNow<deadline) {
                    Dictionary<string,object> result;
                    if(mode=="reader"){result=request.ReadResult();}
                    else {
                        using(FileStream file=new FileStream(request.ResultPath,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
                        using(StreamReader reader=new StreamReader(file)){result=json.Deserialize<Dictionary<string,object>>(reader.ReadToEnd());}
                    }
                    if(result==null || Request.Text(result,"operationId")!=request.OperationId || Request.Text(result,"message").Length==0){throw new InvalidDataException("Missing/partial/mismatched result snapshot.");}
                    count++;Thread.Sleep(1);
                }
            } else {
                using(AtomicFile.Acquire(request.ResultPath)) {
                    File.WriteAllText(reportPath+".ready","owns writer lock");
                    if(mode=="abandon"){Environment.Exit(0);}
                    Thread.Sleep(mode=="timeout"?7000:1000);
                }
            }
        } catch(Exception exception){errors.Add(exception.ToString());}
        File.WriteAllText(reportPath,json.Serialize(new Dictionary<string,object>{{"mode",mode},{"count",count},{"errors",errors}}));
        return errors.Count==0?0:1;
    }
}
