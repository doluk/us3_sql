#!/usr/bin/env bash
#
# tests/catalog_smoke.sh - smoke test for the procedures in us3_catalog_procs.sql
#
# Creates a scratch database, loads us3.sql, us3_procedures.sql and
# tests/catalog_fixture.sql into it, then calls every catalog procedure as
# an administrator (for everybody and for one investigator), as the
# investigators themselves and as a stranger, and checks for each call:
#
#   - the status the procedure answers with;
#   - the number of columns of the data set (callers read them by position);
#   - the number of rows, and for some calls which records they are;
#   - that every count get_experiment_summary reports is the number of rows
#     the matching detail procedure returns for the same caller and p_ID.
#
# Usage, from anywhere:
#
#   MYSQL="mysql -h 127.0.0.1 -P 3306 -u root -psecret" tests/catalog_smoke.sh
#
# Environment:
#   MYSQL     the client command line, without a database name (default: mysql).
#             The account needs to create and drop the scratch database and
#             to create routines in it.  On a server with binary logging
#             (the MySQL 8 default) creating the functions in
#             us3_procedures.sql also needs SUPER, or the server variable
#             log_bin_trust_function_creators = 1.
#   SMOKE_DB  the scratch database (default: us3_catalog_smoke).  It is
#             DROPPED and created again on every run.
#   KEEP_DB   set to 1 to leave the scratch database in place afterwards.
#
# Exit status is 0 when every check passes, 1 when any fails and 2 when the
# database could not be set up.

set -u

here=$( cd "$( dirname "$0" )" && pwd )
root=$( dirname "$here" )
MYSQL=${MYSQL:-mysql}
DB=${SMOKE_DB:-us3_catalog_smoke}
KEEP_DB=${KEEP_DB:-0}

tmp=$( mktemp -d )
trap 'rm -rf "$tmp"' EXIT

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

# ---------------------------------------------------------------------------
# Set up the scratch database
# ---------------------------------------------------------------------------

# us3.sql and us3_procedures.sql SOURCE their companion files by relative path
cd "$root" || exit 2

echo "== creating $DB"
$MYSQL -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\`" || exit 2
$MYSQL -N -e "SELECT CONCAT( 'server: ', VERSION() )"

# us3.sql carries statements some servers refuse (see tests/README); load it
# with --force, show what failed, and insist only on the tables the catalog
# procedures read
echo "== loading us3.sql"
sql --force < us3.sql > /dev/null 2> "$tmp/us3.err"
if [ -s "$tmp/us3.err" ]; then
   echo "note: $( grep -c '^ERROR' "$tmp/us3.err" ) statement(s) of us3.sql failed on this server:"
   sed 's/^/   /' "$tmp/us3.err"
fi

for t in people project experiment experimentPerson rawData editedData \
         model modelPerson noise; do
   n=$( sql -N -e "SELECT COUNT(*) FROM information_schema.tables
                   WHERE table_schema = DATABASE() AND table_name = '$t'" )
   if [ "$n" != 1 ]; then
      echo "ERROR: table $t was not created; the catalog procedures need it"
      exit 2
   fi
done

echo "== loading us3_procedures.sql"
sql < us3_procedures.sql > /dev/null || { echo "ERROR: us3_procedures.sql did not load"; exit 2; }

echo "== loading tests/catalog_fixture.sql"
sql < "$here/catalog_fixture.sql" || { echo "ERROR: the fixture did not load"; exit 2; }

# ---------------------------------------------------------------------------
# Calling a procedure
#
# call <procedure> <argument list>
#   sets ST (status), NCOLS (columns of the data set, 0 if there is none),
#   NROWS and ROWS (the data rows, tab separated).
#
# The client prints a header line for each result set, even an empty one,
# when given --column-type-info, so the output of a call is:
#   line 1 "status", line 2 its value, line 3 the data set's header (when
#   there is a data set), then its rows.
# ---------------------------------------------------------------------------
call()
{
   local out
   CALLED="$1( $2 )"
   if ! out=$( sql -B --column-type-info -e "CALL $1( $2 )" 2>&1 ); then
      ST="ERROR: $out"; NCOLS=0; NROWS=0; ROWS=""
      return
   fi

   ST=$( printf '%s\n' "$out" | sed -n 2p )

   if [ "$( printf '%s\n' "$out" | wc -l )" -ge 3 ]; then
      NCOLS=$( printf '%s\n' "$out" | awk -F'\t' 'NR == 3 { print NF }' )
      ROWS=$(  printf '%s\n' "$out" | sed -n '4,$p' )
   else
      NCOLS=0
      ROWS=""
   fi

   if [ -n "$ROWS" ]; then
      NROWS=$( printf '%s\n' "$ROWS" | wc -l )
   else
      NROWS=0
   fi
}

# column <n> : field n (1-based) of every row, space separated
column() { printf '%s\n' "$ROWS" | awk -F'\t' -v c="$1" 'NF { printf "%s%s", s, $c; s = " " }'; }

# expect <status> [<columns> <rows>] : checks on the last call
expect()
{
   check "$CALLED status" "$1" "$ST"
   [ $# -lt 3 ] && return
   # An empty data set has no header with some clients; then there is
   # nothing to count the columns of
   if [ "$3" -gt 0 ] || [ "$NCOLS" -gt 0 ]; then
      check "$CALLED columns" "$2" "$NCOLS"
   fi
   check "$CALLED rows" "$3" "$NROWS"
}

# The people in the fixture
ADMIN="'00000000-0000-4000-8000-000000000901', 'adminpw'"
ALICE="'00000000-0000-4000-8000-000000000902', 'alicepw'"
BOB="'00000000-0000-4000-8000-000000000903', 'bobpw'"
CAROL="'00000000-0000-4000-8000-000000000904', 'carolpw'"
BADPW="'00000000-0000-4000-8000-000000000902', 'wrong'"
NOBODY="'00000000-0000-4000-8000-000000000999', 'nobody'"

OK=0 NOTPERMITTED=201 NOROWS=301 NO_EXPERIMENT=508 NO_ACCT=102 BADPASS=104

SUMMARY_COLS=14 RAW_COLS=11 EDIT_COLS=10 MODEL_COLS=10 NOISE_COLS=10

# ---------------------------------------------------------------------------
# summary <who> <caller> <p_ID> <expected rows>
#
# Expected rows are "experimentID:raw:edit:model:noise" in runID order.  For
# every row the detail procedures are called with the same caller and p_ID
# and must return exactly the counted number of records, and the bulk
# procedures must return the sums.
# ---------------------------------------------------------------------------
summary()
{
   local who=$1 caller=$2 id=$3 want=$4
   local got="" line exp raw edit model noise sraw=0 sedit=0

   echo "-- $who, p_ID $id"
   call get_experiment_summary "$caller, $id"
   expect $OK $SUMMARY_COLS "$( echo $want | wc -w )"

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
      if [ "$raw" -eq 0 ]; then expect $NOROWS; else expect $OK $RAW_COLS "$raw"; fi

      call get_editedData_by_experiment "$caller, $exp"
      if [ "$edit" -eq 0 ]; then expect $NOROWS; else expect $OK $EDIT_COLS "$edit"; fi

      call get_model_desc_by_experiment "$caller, $id, $exp"
      expect $OK $MODEL_COLS "$model"

      call get_noise_desc_by_experiment "$caller, $id, $exp"
      expect $OK $NOISE_COLS "$noise"
   done

   call get_rawData_by_person "$caller, $id"
   expect $OK $RAW_COLS $sraw
   # nothing is hashed: every checksum is NULL
   check "$CALLED checksums" "$( [ $sraw -gt 0 ] && echo NULL )" \
         "$( column 10 | tr ' ' '\n' | sort -u | xargs )"

   call get_editedData_by_person "$caller, $id"
   expect $OK $EDIT_COLS $sedit
}

# refused <who> <caller> <p_ID> <status> : every listing procedure refuses
refused()
{
   echo "-- $1, p_ID $3 (refused)"
   call get_experiment_summary "$2, $3";   expect "$4" 0 0
   call get_rawData_by_person "$2, $3";    expect "$4" 0 0
   call get_editedData_by_person "$2, $3"; expect "$4" 0 0
}

# refused_exp <who> <caller> <experimentID> <status> : so does every detail one
refused_exp()
{
   echo "-- $1, experiment $3 (refused)"
   call get_rawData_by_experiment "$2, $3";        expect "$4" 0 0
   call get_editedData_by_experiment "$2, $3";     expect "$4" 0 0
   call get_model_desc_by_experiment "$2, 0, $3";  expect "$4" 0 0
   call get_noise_desc_by_experiment "$2, 0, $3";  expect "$4" 0 0
}

echo "== listing"

# smoke_alpha (9101) has three experimentPerson rows and is listed once; its
# model 9404 and noise 9503 have no modelPerson row and are counted for
# nobody; bob's model 9403 and noise 9502 count only for bob or everybody
ALL="9101:2:3:3:3 9102:0:0:0:0 9103:1:1:1:1"
OF_ALICE="9101:2:3:2:2 9102:0:0:0:0"
OF_BOB="9101:2:3:1:1 9103:1:1:1:1"

summary "admin"        "$ADMIN" 0   "$ALL"
summary "admin"        "$ADMIN" 902 "$OF_ALICE"
summary "admin"        "$ADMIN" 903 "$OF_BOB"
summary "admin"        "$ADMIN" 904 ""
summary "alice"        "$ALICE" 0   "$OF_ALICE"
summary "alice"        "$ALICE" 902 "$OF_ALICE"
summary "bob"          "$BOB"   0   "$OF_BOB"
summary "carol"        "$CAROL" 0   ""

refused "alice"        "$ALICE"  903 $NOTPERMITTED
refused "carol"        "$CAROL"  902 $NOTPERMITTED
refused "bad password" "$BADPW"  0   $BADPASS
refused "no account"   "$NOBODY" 0   $NO_ACCT

echo "== details"

refused_exp "carol"        "$CAROL"  9101   $NOTPERMITTED
refused_exp "bob"          "$BOB"    9102   $NOTPERMITTED
refused_exp "alice"        "$ALICE"  9103   $NOTPERMITTED
refused_exp "alice"        "$ALICE"  999999 $NO_EXPERIMENT
refused_exp "bad password" "$BADPW"  9101   $BADPASS

echo "-- which records"

call get_model_desc_by_experiment "$ADMIN, 0, 9101"
check "$CALLED modelIDs" "9403 9402 9401" "$( column 1 )"
call get_model_desc_by_experiment "$ALICE, 0, 9101"
check "$CALLED modelIDs" "9402 9401" "$( column 1 )"
call get_model_desc_by_experiment "$ALICE, 903, 9101"     # p_ID ignored for a user
check "$CALLED modelIDs" "9402 9401" "$( column 1 )"
call get_model_desc_by_experiment "$BOB, 0, 9101"
check "$CALLED modelIDs" "9403" "$( column 1 )"

call get_noise_desc_by_experiment "$ADMIN, 0, 9101"
check "$CALLED noiseIDs" "9501 9502 9504" "$( column 1 | tr ' ' '\n' | sort | xargs )"
call get_noise_desc_by_experiment "$ALICE, 0, 9101"
check "$CALLED noiseIDs" "9501 9504" "$( column 1 | tr ' ' '\n' | sort | xargs )"
call get_noise_desc_by_experiment "$BOB, 0, 9101"
check "$CALLED noiseIDs" "9502" "$( column 1 )"

call get_rawData_by_experiment "$ALICE, 9101"
check "$CALLED rawDataIDs" "9201 9202" "$( column 1 )"
check "$CALLED checksums" \
      "$( sql -N -e "SELECT CONCAT( MD5( 'RAW-9201' ), ' ', MD5( 'RAW-9202' ) )" )" \
      "$( column 10 )"
check "$CALLED sizes" "8 8" "$( column 11 )"

call get_editedData_by_experiment "$ALICE, 9101"
check "$CALLED editedDataIDs" "9301 9303 9302" "$( column 1 )"    # by filename
check "$CALLED rawDataGUIDs" \
      "00000000-0000-4000-8000-000000009201 00000000-0000-4000-8000-000000009202 00000000-0000-4000-8000-000000009201" \
      "$( column 3 )"

# Linked to nobody: listed for no one, but an administrator may still open it
call get_rawData_by_experiment "$ADMIN, 9104"
expect $OK $RAW_COLS 1
call get_model_desc_by_experiment "$ADMIN, 0, 9104"
expect $OK $MODEL_COLS 0

call get_rawData_by_person "$ADMIN, 0"
check "$CALLED rawDataIDs" "9201 9202 9203" "$( column 1 )"
call get_editedData_by_person "$ADMIN, 0"
check "$CALLED editedDataIDs" "9301 9303 9302 9304" "$( column 1 )"    # by experiment, filename

# ---------------------------------------------------------------------------
echo "== $pass passed, $fail failed"

if [ "$KEEP_DB" != 1 ]; then
   $MYSQL -e "DROP DATABASE IF EXISTS \`$DB\`"
fi

[ "$fail" -eq 0 ]
