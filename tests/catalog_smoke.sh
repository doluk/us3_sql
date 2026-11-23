#!/usr/bin/env bash
#
# tests/catalog_smoke.sh - smoke test for the procedures in us3_catalog_procs.sql
#
# Creates a scratch database, loads us3.sql, us3_procedures.sql and
# tests/catalog_fixture.sql into it, then calls every catalog procedure as
# an administrator (for everybody and for one investigator), as the
# investigators themselves, as a stranger and with every kind of failed
# login, and checks for each call:
#
#   - the status the procedure answers with;
#   - the NAMES and order of the data set's columns, against the golden
#     lists below (callers read the columns by position);
#   - the number of rows, and for many calls which records, in which order;
#   - checksums and sizes (and that the *_by_person procedures hash nothing),
#     and that every UTC_ column is a converted DATETIME with the value
#     timestamp2UTC() gives for the fixture's timestamp;
#   - that every count get_experiment_summary reports is the number of rows
#     the matching detail procedure returns for the same caller and p_ID.
#
# Usage, from anywhere:
#
#   MYSQL="mysql --defaults-extra-file=$HOME/smoke.cnf" tests/catalog_smoke.sh
#
# with the host, port, user and password in that file's [client] group, or
# with the password in MYSQL_PWD.  A password given as -p... works too, but
# the client then warns on every call.
#
# Environment:
#   MYSQL     the client command line, without a database name (default: mysql).
#             The account needs to create and drop the scratch database and
#             to create routines in it.  On a server with binary logging
#             (the MySQL 8 default) creating the functions in
#             us3_procedures.sql also needs SUPER, or the server variable
#             log_bin_trust_function_creators = 1.
#   SMOKE_DB  the scratch database (default: us3_catalog_smoke).  It is
#             DROPPED and created again on every run, and dropped at the end.
#   KEEP_DB   set to 1 to leave the scratch database in place afterwards.
#   SMOKE_CATALOG
#             a catalog procedures file to load after us3_procedures.sql,
#             over the one it sources (tests/catalog_mutations.sh uses this
#             to load broken copies).
#
# The client's standard error goes to a file, never into what is parsed;
# whether a call worked is decided by the client's exit status.
#
# Exit status is 0 when every check passes, 1 when any fails and 2 when the
# database could not be set up.

set -u

here=$( cd "$( dirname "$0" )" && pwd )
root=$( dirname "$here" )
MYSQL=${MYSQL:-mysql}
DB=${SMOKE_DB:-us3_catalog_smoke}
KEEP_DB=${KEEP_DB:-0}
CATALOG=${SMOKE_CATALOG:-}

tmp=$( mktemp -d )
created=0

cleanup()
{
   if [ "$created" = 1 ] && [ "$KEEP_DB" != 1 ]; then
      $MYSQL -e "DROP DATABASE IF EXISTS \`$DB\`" 2> "$tmp/drop.err" ||
         { echo "warning: could not drop $DB:"; cat "$tmp/drop.err"; }
   fi
   rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 2' INT TERM HUP

pass=0
fail=0

ok()  { pass=$(( pass + 1 )); }
bad() { fail=$(( fail + 1 )); echo "FAIL: $*"; }

# check <description> <expected> <actual>
check()
{
   if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$2', got '$3'"; fi
}

sql() { $MYSQL "$DB" "$@"; }

# setup_step <what> <command...> : run a setup command, stderr to a file
setup_step()
{
   local what=$1; shift
   if ! "$@" > /dev/null 2> "$tmp/setup.err"; then
      echo "ERROR: $what failed:"
      sed 's/^/   /' "$tmp/setup.err"
      exit 2
   fi
}

# ---------------------------------------------------------------------------
# Set up the scratch database
# ---------------------------------------------------------------------------

# us3.sql and us3_procedures.sql SOURCE their companion files by relative path
cd "$root" || exit 2

echo "== creating $DB"
setup_step "creating $DB" \
   $MYSQL -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\`"
created=1
$MYSQL -N -e "SELECT CONCAT( 'server: ', VERSION() )" 2> /dev/null

# us3.sql carries statements some servers refuse (see tests/README); load it
# with --force, show what failed, and insist only on the tables the catalog
# procedures read
echo "== loading us3.sql"
sql --force < us3.sql > /dev/null 2> "$tmp/us3.err"
if grep -q '^ERROR' "$tmp/us3.err"; then
   echo "note: $( grep -c '^ERROR' "$tmp/us3.err" ) statement(s) of us3.sql failed on this server:"
   grep '^ERROR' "$tmp/us3.err" | sed 's/^/   /'
fi

for t in people project experiment experimentPerson rawData editedData \
         model modelPerson noise; do
   n=$( sql -N -e "SELECT COUNT(*) FROM information_schema.tables
                   WHERE table_schema = DATABASE() AND table_name = '$t'" 2> /dev/null )
   if [ "$n" != 1 ]; then
      echo "ERROR: table $t was not created; the catalog procedures need it"
      exit 2
   fi
done

echo "== loading us3_procedures.sql"
setup_step "loading us3_procedures.sql" sql -e "SOURCE us3_procedures.sql"

if [ -n "$CATALOG" ]; then
   echo "== loading $CATALOG"
   setup_step "loading $CATALOG" sql -e "SOURCE $CATALOG"
fi

echo "== loading tests/catalog_fixture.sql"
setup_step "loading the fixture" sql -e "SOURCE $here/catalog_fixture.sql"

# ---------------------------------------------------------------------------
# The golden column lists.  These are the columns, in order, that the row
# readers of UltraScan3's catalog take by position (utils/us_data_catalog.cpp:
# loadRunsDbBulk for the summary; raw_row, edit_row, model_row, noise_row
# for the rest), named as the procedures' SELECTs name them.  A column
# moved, renamed, dropped or added breaks the client, so it fails here.
# ---------------------------------------------------------------------------
SUMMARY_COLS="experimentID experimentGUID runID type runType label projectID projectGUID projectDescription UTC_dateUpdated rawCount editCount modelCount noiseCount"
RAW_COLS="rawDataID rawDataGUID label filename comment experimentID solutionID channelID UTC_lastUpdated checksum size"
EDIT_COLS="editedDataID rawDataID rawDataGUID editGUID label filename comment UTC_lastUpdated checksum size"
MODEL_COLS="modelID modelGUID description variance meniscus editGUID editedDataID UTC_lastUpdated checksum size"
NOISE_COLS="noiseID noiseGUID editedDataID modelID noiseType modelGUID UTC_timeEntered checksum size description"

# ---------------------------------------------------------------------------
# Calling a procedure
#
# call <procedure> <argument list>
#   sets ST (status), COLS (the data set's column names, space separated,
#   empty if there is none), NROWS and ROWS (the data rows, tab separated).
#
# In batch mode, with --column-type-info, the client prints a header line
# for each result set, even an empty one (MySQL; MariaDB leaves it out for
# an empty one), so the output of a call is: line 1 "status", line 2 its
# value, line 3 the data set's header (when there is a data set), then its
# rows.  Standard error goes to its own file, and a call that the client
# reports as failed is an "ERROR" status, whatever it printed.
# ---------------------------------------------------------------------------
call()
{
   CALLED="$1( $2 )"
   COLS="" ROWS="" NROWS=0

   if ! sql -B --column-type-info -e "CALL $1( $2 )" \
            > "$tmp/out" 2> "$tmp/err"; then
      ST="ERROR: $( grep -v -i 'warning' "$tmp/err" | head -3 | tr '\n' ' ' )"
      return
   fi

   if [ "$( sed -n 1p "$tmp/out" )" != status ]; then
      ST="ERROR: unexpected output: $( head -c 200 "$tmp/out" | tr '\n' ' ' )"
      return
   fi

   ST=$( sed -n 2p "$tmp/out" )
   COLS=$( sed -n 3p "$tmp/out" | tr '\t' ' ' )
   ROWS=$( sed -n '4,$p' "$tmp/out" )

   if [ -n "$ROWS" ]; then
      NROWS=$( printf '%s\n' "$ROWS" | wc -l )
   fi
}

# column <n> : field n (1-based) of every row, space separated
column() { printf '%s\n' "$ROWS" | awk -F'\t' -v c="$1" 'NF { printf "%s%s", s, $c; s = " " }'; }

# field <row> <n> : field n of row number row (both 1-based)
field() { printf '%s\n' "$ROWS" | awk -F'\t' -v r="$1" -v c="$2" 'NR == r { print $c }'; }

# expect <status> [<golden columns> <rows>] : checks on the last call
expect()
{
   check "$CALLED status" "$1" "$ST"
   [ $# -lt 3 ] && return
   # An empty data set has no header with some clients; then there are no
   # names to compare
   if [ "$3" -gt 0 ] || [ -n "$COLS" ]; then
      check "$CALLED columns" "$2" "$COLS"
   fi
   check "$CALLED rows" "$3" "$NROWS"
}

# refused_only <status> : the last call answered that status and nothing else
refused_only()
{
   check "$CALLED status" "$1" "$ST"
   check "$CALLED has no data set" "" "$COLS$ROWS"
}

# coltypes <procedure> <argument list> : the type of each column of the
# call's last result set, as "name:TYPE ..."
coltypes()
{
   sql -t --column-type-info -e "CALL $1( $2 )" 2> "$tmp/err" |
      awk '/^Field +[0-9]+:/ { if ( $2 == "1:" ) { out = ""; s = "" }
                               name = $3; gsub( /`/, "", name ) }
           /^Type:/          { out = out s name ":" $2; s = " " }
           END               { print out }'
}

# utc <timestamp> : what timestamp2UTC() makes of it on this server, after
# config() has set the offset it falls back on without time zone tables
utc() { sql -N -e "CALL config(); SELECT timestamp2UTC( '$1' )" 2> /dev/null; }

# md5 <text> ... : MD5 of each, space separated
md5()
{
   local t out="" s=""
   for t in "$@"; do
      out="$out$s$( sql -N -e "SELECT MD5( '$t' )" 2> /dev/null )"; s=" "
   done
   echo "$out"
}

# The people in the fixture
ADMIN="'00000000-0000-4000-8000-000000000901', 'adminpw'"
ALICE="'00000000-0000-4000-8000-000000000902', 'alicepw'"
BOB="'00000000-0000-4000-8000-000000000903', 'bobpw'"
CAROL="'00000000-0000-4000-8000-000000000904', 'carolpw'"
DAVE="'00000000-0000-4000-8000-000000000905', 'davepw'"      # not activated
ERIN="'00000000-0000-4000-8000-000000000906', 'erinpw'"      # disabled
FRANK="'00000000-0000-4000-8000-000000000907', 'frankpw'"    # userlevel 1
BADPW="'00000000-0000-4000-8000-000000000902', 'wrong'"
NOBODY="'00000000-0000-4000-8000-000000000999', 'nobody'"
NOGUID="'', 'alicepw'"

OK=0 NOTPERMITTED=201 NOROWS=301 NO_EXPERIMENT=508
NO_ACCT=102 INACTIVE=103 BADPASS=104 EMPTY=105

# ---------------------------------------------------------------------------
# summary <who> <caller> <p_ID> <expected rows>
#
# Expected rows are "experimentID:raw:edit:model:noise" in runID order.  For
# every row the detail procedures are called with the same caller and p_ID
# and must return exactly the counted number of records, and the bulk
# procedures must return the sums, with nothing hashed.
# ---------------------------------------------------------------------------
summary()
{
   local who=$1 caller=$2 id=$3 want=$4
   local got="" line exp raw edit model noise sraw=0 sedit=0

   echo "-- $who, p_ID $id"
   call get_experiment_summary "$caller, $id"
   expect $OK "$SUMMARY_COLS" "$( echo $want | wc -w )"

   while IFS=$'\t' read -r -a f; do
      [ ${#f[@]} -eq 0 ] && continue
      exp=${f[0]} raw=${f[10]} edit=${f[11]} model=${f[12]} noise=${f[13]}
      got="$got${got:+ }$exp:$raw:$edit:$model:$noise"
      sraw=$(( sraw + raw )) sedit=$(( sedit + edit ))
   done <<< "$ROWS"
   check "$who p_ID $id summary rows" "$want" "$got"

   for line in $got; do
      IFS=: read -r exp raw edit model noise <<< "$line"

      call get_rawData_by_experiment "$caller, $exp"
      if [ "$raw" -eq 0 ]; then refused_only $NOROWS; else expect $OK "$RAW_COLS" "$raw"; fi

      call get_editedData_by_experiment "$caller, $exp"
      if [ "$edit" -eq 0 ]; then refused_only $NOROWS; else expect $OK "$EDIT_COLS" "$edit"; fi

      call get_model_desc_by_experiment "$caller, $id, $exp"
      expect $OK "$MODEL_COLS" "$model"

      call get_noise_desc_by_experiment "$caller, $id, $exp"
      expect $OK "$NOISE_COLS" "$noise"
   done

   # Nothing is hashed: every checksum and size is NULL
   call get_rawData_by_person "$caller, $id"
   expect $OK "$RAW_COLS" $sraw
   check "$CALLED checksums" "$( [ $sraw -gt 0 ] && echo NULL )" \
         "$( column 10 | tr ' ' '\n' | sort -u | xargs )"
   check "$CALLED sizes" "$( [ $sraw -gt 0 ] && echo NULL )" \
         "$( column 11 | tr ' ' '\n' | sort -u | xargs )"

   call get_editedData_by_person "$caller, $id"
   expect $OK "$EDIT_COLS" $sedit
   check "$CALLED checksums" "$( [ $sedit -gt 0 ] && echo NULL )" \
         "$( column 9 | tr ' ' '\n' | sort -u | xargs )"
   check "$CALLED sizes" "$( [ $sedit -gt 0 ] && echo NULL )" \
         "$( column 10 | tr ' ' '\n' | sort -u | xargs )"
}

# refused <who> <caller> <p_ID> <status> : every listing procedure refuses
refused()
{
   echo "-- $1, p_ID $3 (refused)"
   call get_experiment_summary "$2, $3";   refused_only "$4"
   call get_rawData_by_person "$2, $3";    refused_only "$4"
   call get_editedData_by_person "$2, $3"; refused_only "$4"
}

# refused_exp <who> <caller> <experimentID> <status> : so does every detail one
refused_exp()
{
   echo "-- $1, experiment $3 (refused)"
   call get_rawData_by_experiment "$2, $3";        refused_only "$4"
   call get_editedData_by_experiment "$2, $3";     refused_only "$4"
   call get_model_desc_by_experiment "$2, 0, $3";  refused_only "$4"
   call get_noise_desc_by_experiment "$2, 0, $3";  refused_only "$4"
}

echo "== listing"

# runID order: smoke_alpha (9101), smoke_beta (9102), smoke_gamma (9103),
# smoke_magic (1); smoke_delta (9104) is linked to nobody.
#
# smoke_alpha has three experimentPerson rows and is listed once; its model
# 9404 and noise 9503 have no modelPerson row and are counted for nobody;
# bob's model 9403 and noise 9502 count only for bob or everybody.  Noise
# 9508 was computed from alpha's edit but fitted with gamma's model, so it
# is gamma's; noise 9509 of a model on the UNASSIGNED edit is nobody's.
ALL="9101:2:3:3:3 9102:0:0:0:0 9103:1:1:1:2 1:1:1:1:1"
OF_ALICE="9101:2:3:2:2 9102:0:0:0:0"
OF_BOB="9101:2:3:1:1 9103:1:1:1:2 1:1:1:1:1"

summary "admin"        "$ADMIN" 0   "$ALL"
summary "admin"        "$ADMIN" 902 "$OF_ALICE"
summary "admin"        "$ADMIN" 903 "$OF_BOB"
summary "admin"        "$ADMIN" 904 ""
summary "alice"        "$ALICE" 0   "$OF_ALICE"
summary "alice"        "$ALICE" 902 "$OF_ALICE"
summary "bob"          "$BOB"   0   "$OF_BOB"
summary "carol"        "$CAROL" 0   ""

refused "alice"          "$ALICE"  903 $NOTPERMITTED
refused "carol"          "$CAROL"  902 $NOTPERMITTED
refused "bad password"   "$BADPW"  0   $BADPASS
refused "no account"     "$NOBODY" 0   $NO_ACCT
refused "not activated"  "$DAVE"   0   $INACTIVE
refused "disabled"       "$ERIN"   0   $INACTIVE
refused "userlevel 1"    "$FRANK"  0   $BADPASS
refused "empty GUID"     "$NOGUID" 0   $EMPTY

echo "== details"

refused_exp "carol"          "$CAROL"  9101   $NOTPERMITTED
refused_exp "bob"            "$BOB"    9102   $NOTPERMITTED
refused_exp "alice"          "$ALICE"  9103   $NOTPERMITTED
refused_exp "alice"          "$ALICE"  999999 $NO_EXPERIMENT
refused_exp "bad password"   "$BADPW"  9101   $BADPASS
refused_exp "not activated"  "$DAVE"   9101   $INACTIVE
refused_exp "disabled"       "$ERIN"   9101   $INACTIVE
refused_exp "userlevel 1"    "$FRANK"  9101   $BADPASS
refused_exp "empty GUID"     "$NOGUID" 9101   $EMPTY

# Experiment 1 is bob's.  verify_experiment_permission() lets anyone at it;
# the catalog procedures must not
refused_exp "alice"          "$ALICE"  1      $NOTPERMITTED
refused_exp "carol"          "$CAROL"  1      $NOTPERMITTED
call get_rawData_by_experiment "$ADMIN, 1"
expect $OK "$RAW_COLS" 1
call get_noise_desc_by_experiment "$BOB, 0, 1"
expect $OK "$NOISE_COLS" 1

echo "-- which records, in which order"

call get_experiment_summary "$ADMIN, 0"
check "$CALLED runIDs" "smoke_alpha smoke_beta smoke_gamma smoke_magic" "$( column 3 )"
check "$CALLED experimentGUIDs" \
      "00000000-0000-4000-8000-000000009101 00000000-0000-4000-8000-000000009102 00000000-0000-4000-8000-000000009103 00000000-0000-4000-8000-000000009100" \
      "$( column 2 )"
check "$CALLED types"    "velocity velocity velocity velocity" "$( column 4 )"
check "$CALLED runTypes" "RI RI IP RI"                         "$( column 5 )"
check "$CALLED labels"   "alpha beta gamma magic"              "$( column 6 )"
check "$CALLED projectIDs"   "9001 9001 NULL NULL"             "$( column 7 )"
check "$CALLED projectGUIDs" \
      "00000000-0000-4000-8000-000000009001 00000000-0000-4000-8000-000000009001 NULL NULL" \
      "$( column 8 )"
check "$CALLED UTC_dateUpdated of smoke_alpha" "$( utc '2026-01-01 10:00:00' )" \
      "$( field 1 10 )"

call get_rawData_by_experiment "$ALICE, 9101"
check "$CALLED rawDataIDs" "9202 9201" "$( column 1 )"          # by filename
check "$CALLED labels"     "smoke_alpha smoke_alpha" "$( column 3 )"
check "$CALLED filenames"  "smoke_alpha.RI.1.A.290.auc smoke_alpha.RI.2.A.280.auc" "$( column 4 )"
check "$CALLED experimentIDs" "9101 9101" "$( column 6 )"
check "$CALLED UTC_lastUpdated of 9202" "$( utc '2026-01-01 11:30:00' )" "$( field 1 9 )"
check "$CALLED checksums" "$( md5 RAW-9202x RAW-9201 )" "$( column 10 )"
check "$CALLED sizes" "9 8" "$( column 11 )"

call get_editedData_by_experiment "$ALICE, 9101"
check "$CALLED editedDataIDs" "9303 9301 9302" "$( column 1 )"    # by filename
check "$CALLED rawDataIDs"    "9202 9201 9201" "$( column 2 )"
check "$CALLED rawDataGUIDs" \
      "00000000-0000-4000-8000-000000009202 00000000-0000-4000-8000-000000009201 00000000-0000-4000-8000-000000009201" \
      "$( column 3 )"
check "$CALLED editGUIDs" \
      "00000000-0000-4000-8000-000000009303 00000000-0000-4000-8000-000000009301 00000000-0000-4000-8000-000000009302" \
      "$( column 4 )"
check "$CALLED UTC_lastUpdated of 9303" "$( utc '2026-01-01 12:30:00' )" "$( field 1 8 )"
check "$CALLED checksums" "$( md5 EDIT-9303x EDIT-9301 EDIT-9302xx )" "$( column 9 )"
check "$CALLED sizes" "10 9 11" "$( column 10 )"

call get_model_desc_by_experiment "$ADMIN, 0, 9101"
check "$CALLED modelIDs" "9403 9402 9401" "$( column 1 )"        # newest ID first
check "$CALLED variances" "0.75 0.5 0.25" "$( column 4 )"
check "$CALLED meniscus"  "5.9375 6.125 5.875" "$( column 5 )"
check "$CALLED editedDataIDs" "9301 9302 9301" "$( column 7 )"
check "$CALLED UTC_lastUpdated of 9403" "$( utc '2026-01-01 15:00:00' )" "$( field 1 8 )"
check "$CALLED checksums" \
      "$( md5 '<model id="9403"/>' '<model id="9402"/>' '<model id="9401"/>' )" \
      "$( column 9 )"
check "$CALLED sizes" "18 18 18" "$( column 10 )"
call get_model_desc_by_experiment "$ALICE, 0, 9101"
check "$CALLED modelIDs" "9402 9401" "$( column 1 )"
call get_model_desc_by_experiment "$ALICE, 903, 9101"     # p_ID ignored for a user
check "$CALLED modelIDs" "9402 9401" "$( column 1 )"
call get_model_desc_by_experiment "$BOB, 0, 9101"
check "$CALLED modelIDs" "9403" "$( column 1 )"

call get_noise_desc_by_experiment "$ADMIN, 0, 9101"
check "$CALLED noiseIDs" "9502 9504 9501" "$( column 1 )"        # newest first
check "$CALLED editedDataIDs" "9301 9302 9301" "$( column 3 )"
check "$CALLED modelIDs" "9403 9401 9401" "$( column 4 )"
check "$CALLED noiseTypes" "ri_noise ri_noise ti_noise" "$( column 5 )"
check "$CALLED UTC_timeEntered of 9502" "$( utc '2026-01-01 18:00:00' )" "$( field 1 7 )"
check "$CALLED checksums" \
      "$( md5 '<noise id="9502"/>' '<noise id="9504"/>' '<noise id="9501"/>' )" \
      "$( column 8 )"
check "$CALLED sizes" "18 18 18" "$( column 9 )"
check "$CALLED descriptions" \
      "smoke_alpha.1A280.ga.ri_noise smoke_alpha.1A280.2dsa.ri_noise smoke_alpha.1A280.2dsa.ti_noise" \
      "$( column 10 )"
call get_noise_desc_by_experiment "$ALICE, 0, 9101"
check "$CALLED noiseIDs" "9504 9501" "$( column 1 )"
call get_noise_desc_by_experiment "$BOB, 0, 9101"
check "$CALLED noiseIDs" "9502" "$( column 1 )"

# Global-fit noise is in its model's experiment, and keeps its own edit
call get_noise_desc_by_experiment "$BOB, 0, 9103"
check "$CALLED noiseIDs" "9508 9505" "$( column 1 )"
check "$CALLED editedDataIDs" "9303 9304" "$( column 3 )"

# Linked to nobody: listed for no one, but an administrator may still open it
call get_rawData_by_experiment "$ADMIN, 9104"
expect $OK "$RAW_COLS" 1
call get_model_desc_by_experiment "$ADMIN, 0, 9104"
expect $OK "$MODEL_COLS" 0

call get_rawData_by_person "$ADMIN, 0"
check "$CALLED rawDataIDs" "9205 9202 9201 9203" "$( column 1 )"   # by experiment, filename
check "$CALLED UTC_lastUpdated of 9205" "$( utc '2026-01-05 11:00:00' )" "$( field 1 9 )"
call get_editedData_by_person "$ADMIN, 0"
check "$CALLED editedDataIDs" "9305 9303 9301 9302 9304" "$( column 1 )"
check "$CALLED rawDataGUIDs" \
      "00000000-0000-4000-8000-000000009205 00000000-0000-4000-8000-000000009202 00000000-0000-4000-8000-000000009201 00000000-0000-4000-8000-000000009201 00000000-0000-4000-8000-000000009203" \
      "$( column 3 )"

echo "-- column types"

# A UTC_ column is timestamp2UTC()'s DATETIME; the bare TIMESTAMP column
# would mean the conversion was dropped (which on a server running in UTC
# would not show in the values)
utc_types()
{
   check "$1 UTC_ column types" "$3" \
         "$( printf '%s\n' $( coltypes "$1" "$2" ) | grep '^UTC_' | xargs )"
}
utc_types get_experiment_summary       "$ADMIN, 0"       "UTC_dateUpdated:DATETIME"
utc_types get_rawData_by_experiment    "$ALICE, 9101"    "UTC_lastUpdated:DATETIME"
utc_types get_editedData_by_experiment "$ALICE, 9101"    "UTC_lastUpdated:DATETIME"
utc_types get_model_desc_by_experiment "$ALICE, 0, 9101" "UTC_lastUpdated:DATETIME"
utc_types get_noise_desc_by_experiment "$ALICE, 0, 9101" "UTC_timeEntered:DATETIME"
utc_types get_rawData_by_person        "$ADMIN, 0"       "UTC_lastUpdated:DATETIME"
utc_types get_editedData_by_person     "$ADMIN, 0"       "UTC_lastUpdated:DATETIME"

echo "-- the single-edit procedures they stand in for"

# get_model_desc_by_editID and get_noise_desc_by_editID are read with the
# same code as the per-experiment procedures, so their columns must match
call get_model_desc_by_editID "$ALICE, 902, 9301"
expect $OK "$MODEL_COLS" 1
call get_noise_desc_by_editID "$ALICE, 902, 9301"
expect $OK "$NOISE_COLS" 2

# ---------------------------------------------------------------------------
echo "== $pass passed, $fail failed"

[ "$fail" -eq 0 ]
