/// Parallel coordinator for the Gaia DR3 variability analysis.
///
/// Fans the 20 input files out across %SYSTEM.WorkMgr worker jobs (each a separate
/// process running embedded Python, so parsing scales across cores with no GIL
/// contention), then concatenates the per-file .part results into the final CSV
/// with the required header. The heavy lifting (gzip + flux-array parsing) lives
/// in the embedded-Python analyzer; this class is just the fan-out + merge.
Class Gaia.Analyze
{

Parameter HEADER = "source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change";

/// Run the whole pipeline. Returns the number of qualifying rows written.
ClassMethod Run(inDir As %String, outPath As %String) As %Integer
{
  Set tmpDir = "/home/irisowner/dev/data/temp/parts"
  Do ##class(%File).CreateDirectoryChain(tmpDir)
  Do ##class(%File).CreateDirectoryChain(##class(%File).GetDirectory(outPath))

  // Discover the input files.
  Set rs = ##class(%File).FileSetFunc(inDir, "EpochPhotometry_*.csv.gz", , 1)
  Set files = 0
  While rs.%Next() {
    Set files = files + 1
    Set file(files) = rs.Name
    Set part(files) = tmpDir_"/part_"_files_".csv"
  }

  // Fan out: one queued unit of work per file.
  Set q = ##class(%SYSTEM.WorkMgr).Initialize(, .sc)
  $$$ThrowOnError(sc)
  For i=1:1:files {
    Set sc = q.QueueCallback("##class(Gaia.Work).ProcessFile", "", file(i), part(i))
    $$$ThrowOnError(sc)
  }
  $$$ThrowOnError(q.WaitForComplete())

  // Merge the .part files into the final CSV in Python (fast bulk IO; the
  // ObjectScript stream ReadLine loop was the bottleneck at this scale).
  Set sys = ##class(%SYS.Python).Import("sys")
  Do sys.path.append("/home/irisowner/dev/src")
  Set builtins = ##class(%SYS.Python).Import("builtins")
  Set plist = builtins.list()
  For i=1:1:files { Do plist.append(part(i)) }
  Set analyze = ##class(%SYS.Python).Import("gaia.analyze")
  Set total = analyze."merge_parts"(plist, outPath)

  // clean up the per-file parts
  For i=1:1:files { Do ##class(%File).Delete(part(i)) }
  Quit total
}

}
