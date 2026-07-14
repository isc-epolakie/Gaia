/// Coordinator for the Gaia DR3 variability analysis.
///
/// Fans the input files out across %SYSTEM.WorkMgr worker jobs (each a separate
/// process running embedded Python, so parsing scales across cores with no GIL
/// contention). On the C-kernel path each worker appends its qualifying rows
/// straight to the shared output CSV under an flock, so there is no merge pass.
///
/// The coordinator itself is pure ObjectScript on that path -- it never imports
/// embedded Python. That matters because the very first %SYS.Python call in a
/// process pays a ~0.04s interpreter init, plus module-import cost; doing file
/// discovery ($ZSEARCH, ~0.01s) and the header write (low-level OPEN/WRITE) in
/// ObjectScript keeps that init entirely out of the coordinator. Only the
/// pure-Python fallback (no C kernel available) touches Python here.
Class Gaia.Analyze
{

Parameter HEADER = "source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change";

/// Run the whole pipeline. Returns the number of qualifying rows written.
ClassMethod Run(inDir As %String, outPath As %String) As %Integer
{
  // Discover the input files and order them biggest-first (longest-processing-
  // time-first scheduling), entirely in ObjectScript. $ZSEARCH + GetFileSize is
  // ~0.01s and, unlike the Python glob, needs no interpreter in this process.
  // filesBySize(negativeSize, path) -> "" gives descending-size $ORDER traversal.
  Set n = 0
  Set f = $ZSearch(inDir_"/EpochPhotometry_*.csv.gz")
  While f '= "" {
    Set filesBySize(-##class(%File).GetFileSize(f), f) = ""
    Set n = n + 1
    Set f = $ZSearch("")
  }

  // Prefer the shared-append C-kernel path; fall back to the pure-Python
  // analyzer + merge only if the C kernel isn't importable in a worker.
  Set shared = ..CKernelAvailable()

  If shared {
    // (Re)create the output with just the header (low-level write, ~0.006s), and
    // reset the shared row accumulator the workers add into.
    Open outPath:("NWS")
    Use outPath Write ..#HEADER, ! Close outPath
    Kill ^Gaia.RowCount
  }

  // Fan out: one queued unit of work per file, biggest files first.
  Set tmpDir = "/home/irisowner/dev/data/temp/parts"
  Set q = ##class(%SYSTEM.WorkMgr).Initialize(, .sc)
  $$$ThrowOnError(sc)
  Set i = 0, sz = ""
  For {
    Set sz = $Order(filesBySize(sz))
    Quit:sz=""
    Set ff = ""
    For {
      Set ff = $Order(filesBySize(sz, ff))
      Quit:ff=""
      If shared {
        Set sc = q.QueueCallback("##class(Gaia.Work).ProcessFile", "", ff, "", outPath)
      } Else {
        Set sc = q.QueueCallback("##class(Gaia.Work).ProcessFile", "", ff, tmpDir_"/p_"_i_".csv", "")
      }
      $$$ThrowOnError(sc)
      Set i = i + 1
    }
  }
  $$$ThrowOnError(q.WaitForComplete())

  If shared {
    // Workers already accumulated their row counts in ^Gaia.RowCount, so we
    // return that directly instead of re-reading the (multi-MB) output CSV.
    Quit $Get(^Gaia.RowCount, 0)
  }

  // Fallback: merge the per-file parts into the final CSV (header + concat).
  // Build the parts list as a Python list so it marshals cleanly into merge_parts.
  Set sys = ##class(%SYS.Python).Import("sys")
  Do sys.path.append("/home/irisowner/dev/src")
  Set builtins = ##class(%SYS.Python).Import("builtins")
  Set gmerge = ##class(%SYS.Python).Import("gaia.gmerge")
  Set parts = builtins.list()
  For j=0:1:n-1 { Do parts.append(tmpDir_"/p_"_j_".csv") }
  Quit gmerge."merge_parts"(parts, outPath)
}

/// True if the `ckernel` C extension is present (production fast path). Detected
/// by locating the compiled .so in the user site-packages with $ZSEARCH, so the
/// coordinator needn't import embedded Python (which would defeat the point of a
/// Python-free coordinator). Workers still import the module themselves per job;
/// if the .so is absent here it is absent for them too, so both take the
/// pure-Python fallback consistently.
ClassMethod CKernelAvailable() As %Boolean
{
  Quit ($ZSearch("/home/irisowner/.local/lib/python3.12/site-packages/ckernel*.so") '= "")
}

}
