#!/usr/bin/env bash
# Provision the Gaia results web UI on the IRIS Community built-in web server
# (port 52773), idempotently. Two static CSP applications under /csp/ (the only
# path prefix the built-in server forwards):
#   /csp/gaia/ui   -> web/            (the three.js galaxy page)
#   /csp/gaia/data -> data/out/       (results.csv, fetched by the page)
# Plus UnknownUser enabled so the demo needs no login (local demo only).
#
# Run once after `docker compose up` and after `do ^RunScript` has produced
# data/out/results.csv:
#   bash scripts/setup_web.sh
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose exec -T iris iris session iris -U %SYS <<'EOF'
  set base = "/home/irisowner/dev"

  // static UI app
  if '##class(Security.Applications).Exists("/csp/gaia/ui") {
    kill p
    set p("NameSpace")="USER", p("Path")=base_"/web/", p("Enabled")=1
    set p("ServeFiles")=1, p("ServeFilesTimeout")=3600, p("AutheEnabled")=96
    set sc=##class(Security.Applications).Create("/csp/gaia/ui",.p)
    write "create /csp/gaia/ui: ",$system.Status.GetErrorText(sc),!
  } else { write "create /csp/gaia/ui: already exists",! }

  // static data app (serves data/out/results.csv)
  if '##class(Security.Applications).Exists("/csp/gaia/data") {
    kill q
    set q("NameSpace")="USER", q("Path")=base_"/data/out/", q("Enabled")=1
    set q("ServeFiles")=1, q("ServeFilesTimeout")=3600, q("AutheEnabled")=96
    set sc=##class(Security.Applications).Create("/csp/gaia/data",.q)
    write "create /csp/gaia/data: ",$system.Status.GetErrorText(sc),!
  } else { write "create /csp/gaia/data: already exists",! }

  // UnknownUser = identity for unauthenticated web access (local demo only)
  kill up
  set up("Enabled")=1, up("Roles")="%All", up("Password")="SYS"
  if ##class(Security.Users).Exists("UnknownUser") {
    set sc=##class(Security.Users).Modify("UnknownUser",.up)
    write "modify UnknownUser: ",$system.Status.GetErrorText(sc),!
  } else {
    set sc=##class(Security.Users).Create("UnknownUser",.up)
    write "create UnknownUser: ",$system.Status.GetErrorText(sc),!
  }
  write "web-setup-done",!
  halt
EOF
