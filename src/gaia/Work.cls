/// One unit of parallel work: analyze a single Gaia DR3 file and write its
/// qualifying (>100%) rows to a per-file .part file. Runs inside a %SYSTEM.WorkMgr
/// worker job (its own process + embedded Python, so no GIL contention).
///
/// The worker imports the tiny `ckernel` C extension directly (libdeflate
/// decompress + scan + write, all in C) rather than the heavier gaia.analyze
/// module — importing the full module in every worker cost ~0.9s of the run.
/// Falls back to gaia.analyze.write_part if the C kernel isn't built.
Class Gaia.Work
{

/// bp_flux / rp_flux "[...]"-group indices (arrays start at column 3; bp=col 11,
/// rp=col 16). Fixed by the DR3 layout.
Parameter BPGROUP = 8;

Parameter RPGROUP = 13;

/// Analyze file `inPath`, writing qualifying rows (no header) to `partPath`.
ClassMethod ProcessFile(inPath As %String, partPath As %String) As %Status
{
  Try {
    Set ck = ##class(%SYS.Python).Import("ckernel")
    Do ck."analyze_to_file"(inPath, ..#BPGROUP, ..#RPGROUP, 100, partPath)
  } Catch {
    // Fallback: pure-Python / Cython fast path via the analyzer module.
    Set sys = ##class(%SYS.Python).Import("sys")
    Do sys.path.append("/home/irisowner/dev/src")
    Do ##class(%SYS.Python).Import("gaia.analyze")."write_part"(inPath, partPath)
  }
  Quit $$$OK
}

}
