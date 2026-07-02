/// One unit of parallel work: analyze a single Gaia DR3 file and write its
/// qualifying (>100%) rows to a per-file .part file. Runs inside a %SYSTEM.WorkMgr
/// worker job (its own process + embedded Python, so no GIL contention).
Class Gaia.Work
{

/// Analyze file `inPath`, writing qualifying rows (no header) to `partPath`.
ClassMethod ProcessFile(inPath As %String, partPath As %String) As %Status
{
  Set sys = ##class(%SYS.Python).Import("sys")
  Do sys.path.append("/home/irisowner/dev/src")
  Set analyze = ##class(%SYS.Python).Import("gaia.analyze")
  Do analyze."write_part"(inPath, partPath)
  Quit $$$OK
}

}
