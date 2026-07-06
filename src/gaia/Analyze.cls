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
  Set sys = ##class(%SYS.Python).Import("sys")
  Do sys.path.append("/home/irisowner/dev/src")
  Set gmerge = ##class(%SYS.Python).Import("gaia.gmerge")

  // Discover input files in Python: glob + size sort (biggest-first, for
  // longest-processing-time-first scheduling) is ~0.03s vs ~0.18s for the
  // ObjectScript FileSetFunc glob. Returns parallel (inputs, parts) lists.
  Set plan = gmerge.plan(inDir, tmpDir)
  Set files = plan."__getitem__"(0)      // list of input .csv.gz paths
  Set parts = plan."__getitem__"(1)      // list of per-file .part paths
  Set n = files."__len__"()

  // Prefer the shared-append path: workers flock-append their rows straight to
  // the output CSV, so there is no merge pass. Falls back to per-file parts +
  // merge if the C kernel isn't available. Detect once, up front.
  Set shared = 0
  Try { Do ##class(%SYS.Python).Import("ckernel") Set shared = 1 } Catch { Set shared = 0 }

  // For shared mode: (re)create the output with just the header; workers append.
  If shared {
    Do gmerge."init_output"(outPath)
    Set sharedArg = outPath
  } Else {
    Set sharedArg = ""
  }

  // Fan out: one queued unit of work per file, biggest files first.
  Set q = ##class(%SYSTEM.WorkMgr).Initialize(, .sc)
  $$$ThrowOnError(sc)
  For i=0:1:n-1 {
    Set sc = q.QueueCallback("##class(Gaia.Work).ProcessFile", "", files."__getitem__"(i), parts."__getitem__"(i), sharedArg)
    $$$ThrowOnError(sc)
  }
  $$$ThrowOnError(q.WaitForComplete())

  If shared {
    // rows already in outPath; count them (cheap) for the return value
    Quit gmerge."count_rows"(outPath)
  }
  // Fallback: merge the per-file parts into the final CSV (header + concat).
  Quit gmerge."merge_parts"(parts, outPath)
}

}
