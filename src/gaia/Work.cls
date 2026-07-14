/// One unit of parallel work: analyze a single Gaia DR3 file and append its
/// qualifying (>100%) rows straight to the shared output CSV. Runs inside a
/// %SYSTEM.WorkMgr worker job (its own process + embedded Python, no GIL).
///
/// The worker imports the tiny `ckernel` C extension directly (libdeflate
/// decompress + scan + write, all in C) rather than the heavier gaia.analyze
/// module — importing the full module in every worker cost ~0.9s of the run.
/// ckernel.analyze_to_shared appends every worker's rows to one file under an
/// flock, in a single write() per worker, so there is no separate merge pass and
/// no risk of interleaved lines. Falls back to a private part file + Python
/// analyzer if the C kernel isn't built (the coordinator then merges parts).
Class Gaia.Work
{

/// bp_flux / rp_flux "[...]"-group indices (arrays start at column 3; bp=col 11,
/// rp=col 16). Fixed by the DR3 layout.
Parameter BPGROUP = 8;

Parameter RPGROUP = 13;

/// Analyze `inPath`; on the C-kernel path append rows to `sharedPath`, else write
/// a private part file at `partPath` for the coordinator to merge.
ClassMethod ProcessFile(inPath As %String, partPath As %String, sharedPath As %String = "") As %Status
{
  Try {
    Set ck = ##class(%SYS.Python).Import("ckernel")
    If sharedPath '= "" {
      // analyze_to_shared returns this file's qualifying-row count; accumulate it
      // in a shared global so the coordinator needn't re-read the output CSV to
      // learn the total ($INCREMENT is atomic across the worker processes).
      Set rows = ck."analyze_to_shared"(inPath, ..#BPGROUP, ..#RPGROUP, 100, sharedPath)
      Do $Increment(^Gaia.RowCount, rows)
    } Else {
      Do ck."analyze_to_file"(inPath, ..#BPGROUP, ..#RPGROUP, 100, partPath)
    }
  } Catch {
    // Fallback: pure-Python / Cython fast path -> private part file (merged later).
    Set sys = ##class(%SYS.Python).Import("sys")
    Do sys.path.append("/home/irisowner/dev/src")
    Do ##class(%SYS.Python).Import("gaia.analyze")."write_part"(inPath, partPath)
  }
  Quit $$$OK
}

}
