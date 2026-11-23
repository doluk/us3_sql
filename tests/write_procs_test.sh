#!/usr/bin/env bash
#
# tests/write_procs_test.sh - live-server test for delete_editedData and the
# procedures that report a new record's ID
#
# Loads us3.sql, us3_procedures.sql and tests/catalog_fixture.sql into a
# scratch database, as catalog_smoke.sh does, and checks:
#
#   delete_editedData (us3_expdata_procs.sql)
#     - deletes the edit, its models and their noise wherever it was
#       recorded, and the noise recorded against the edit for a model of
#       another edit (a global fit);
#     - is all or nothing: when the edit cannot be deleted, nothing that
#       depends on it is deleted either, and the status says why --
#       standalone, and inside a caller's open transaction, which it must
#       neither commit nor lose;
#     - refuses the UNASSIGNED edit 1, and strangers.
#
#   create_buffer_component (us3_buffer_procs.sql)
#     - takes a free ID when the table has a gap, and reports that ID (not
#       the connection's previous insert) through last_insertID();
#     - reports 0 when it inserts nothing; add_buffer_component reports 0.
#
# Usage and environment as for catalog_smoke.sh (MYSQL, KEEP_DB); the
# scratch database is WRITE_DB (default: us3_write_procs_test), DROPPED
# first and at the end.  Exit status 0 when every check passes, 1 when any
# fails, 2 when the database could not be set up.

set -u

here=$( cd "$( dirname "$0" )" && pwd )
root=$( dirname "$here" )
MYSQL=${MYSQL:-mysql}
DB=${WRITE_DB:-us3_write_procs_test}
KEEP_DB=${KEEP_DB:-0}

tmp=$( mktemp -d )
created=0

cleanup()
{
   if [ "$created" = 1 ] && [ "$KEEP_DB" != 1 ]; then
      $MYSQL -e "DROP DATABASE IF EXISTS \`$DB\`" 2> /dev/null ||
         echo "warning: could not drop $DB"
   fi
   rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 2' INT TERM HUP

pass=0 fail=0
check()
{
   if [ "$2" = "$3" ]; then pass=$(( pass + 1 ))
   else fail=$(( fail + 1 )); echo "FAIL: $1: expected '$2', got '$3'"; fi
}

# q <sql> : run statements in one session; the output of every result set,
# one line per row, tab separated, no headers; "ERROR" lines if it failed
q()
{
   if ! $MYSQL -N -B "$DB" -e "$1" > "$tmp/out" 2> "$tmp/err"; then
      grep -v -i warning "$tmp/err" | head -2 | sed 's/^/ERROR /'
   fi
   cat "$tmp/out"
}

setup()
{
   if ! "$@" > /dev/null 2> "$tmp/setup.err"; then
      echo "ERROR: setup failed: $*"; sed 's/^/   /' "$tmp/setup.err"; exit 2
   fi
}

cd "$root" || exit 2
echo "== creating $DB"
setup $MYSQL -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\`"
created=1
$MYSQL "$DB" --force < us3.sql > /dev/null 2>&1
setup $MYSQL "$DB" -e "SOURCE us3_procedures.sql"
setup $MYSQL "$DB" -e "SOURCE $here/catalog_fixture.sql"

ALICE="'00000000-0000-4000-8000-000000000902', 'alicepw'"
CAROL="'00000000-0000-4000-8000-000000000904', 'carolpw'"

# The rows that depend on the fixture's edits, as one comparable line
STATE="SELECT CONCAT_WS( ' | ',
         ( SELECT GROUP_CONCAT( editedDataID ORDER BY editedDataID ) FROM editedData ),
         ( SELECT GROUP_CONCAT( modelID ORDER BY modelID ) FROM model ),
         ( SELECT GROUP_CONCAT( modelID ORDER BY modelID ) FROM modelPerson ),
         ( SELECT GROUP_CONCAT( noiseID ORDER BY noiseID ) FROM noise ) )"

FULL="1,9301,9302,9303,9304,9305 | 9401,9402,9403,9404,9405,9406,9407 | 9401,9402,9403,9405,9406,9407 | 9501,9502,9503,9504,9505,9507,9508,9509"

echo "== delete_editedData"

check "fixture" "$FULL" "$( q "$STATE" )"

# A table that refers to edit 9302, standing in for any reference the
# procedure does not clear, so that deleting 9302 fails at the very end
q "CREATE TABLE smoke_ref ( editedDataID INT NOT NULL,
     FOREIGN KEY ( editedDataID ) REFERENCES editedData ( editedDataID ) )
   ENGINE = InnoDB;
   INSERT INTO smoke_ref VALUES ( 9302 );
   CREATE TABLE smoke_outer ( id INT PRIMARY KEY ) ENGINE = InnoDB;" > /dev/null

check "a stranger is refused" "201" \
      "$( q "CALL delete_editedData( $CAROL, 9301 )" )"
check "UNASSIGNED edit 1 is refused" "201" \
      "$( q "CALL delete_editedData( $ALICE, 1 )" )"
check "after the refusals nothing changed" "$FULL" "$( q "$STATE" )"

out=$( q "CALL delete_editedData( $ALICE, 9302 ); SELECT last_errno(), LEFT( last_error(), 42 )" )
check "a failing delete answers CONSTRAINT_FAILED" \
      "404 404 MySQL: the edit was not deleted, and nothi" "$( echo $out )"
check "a failing delete deletes nothing (model 9402, noise 9504 stay)" \
      "$FULL" "$( q "$STATE" )"

out=$( q "START TRANSACTION;
          INSERT INTO smoke_outer VALUES ( 1 );
          CALL delete_editedData( $ALICE, 9302 );
          SELECT COUNT(*) FROM smoke_outer;
          COMMIT;" )
check "failing inside a transaction: status, and the caller's row is still there" \
      "404 1" "$( echo $out )"
check "... which the caller then committed" "1" \
      "$( q "SELECT COUNT(*) FROM smoke_outer" )"
check "... and nothing was deleted" "$FULL" "$( q "$STATE" )"

out=$( q "START TRANSACTION;
          INSERT INTO smoke_outer VALUES ( 2 );
          CALL delete_editedData( $ALICE, 9303 );
          SELECT COUNT(*) FROM editedData WHERE editedDataID = 9303;
          ROLLBACK;" )
check "inside a transaction it deletes, and does not commit the caller's" \
      "0 0" "$( echo $out )"
check "... so the caller's rollback undoes both" "1 | $FULL" \
      "$( q "SELECT CONCAT( ( SELECT COUNT(*) FROM smoke_outer ), ' | ', ( $STATE ) )" )"

# 9303: its model 9404 with noise 9503, and the global-fit noise 9508
# (recorded against 9303, fitted with gamma's model 9405) -- which made the
# old procedure fail half-way
check "deleting edit 9303" "0" "$( q "CALL delete_editedData( $ALICE, 9303 )" )"
check "... took its model, that model's noise and the global-fit noise" \
      "1,9301,9302,9304,9305 | 9401,9402,9403,9405,9406,9407 | 9401,9402,9403,9405,9406,9407 | 9501,9502,9504,9505,9507,9509" \
      "$( q "$STATE" )"

# 9301: models 9401 (alice) and 9403 (bob), their noise 9501, 9502 and
# 9504 (on edit 9302, fitted with 9401), and noise 9509 recorded against it
# for a model on the UNASSIGNED edit; that model, 9407, stays
check "deleting edit 9301" "0" "$( q "CALL delete_editedData( $ALICE, 9301 )" )"
check "... took its models and all their noise, and the noise recorded against it" \
      "1,9302,9304,9305 | 9402,9405,9406,9407 | 9402,9405,9406,9407 | 9505,9507" \
      "$( q "$STATE" )"

echo "== create_buffer_component"

# us3.sql loads components 1-104; a gap at 3 made the old row-count ID (104)
# collide
q "DELETE FROM bufferComponent WHERE bufferComponentID = 3" > /dev/null

out=$( q "INSERT INTO project ( projectGUID, description )
            VALUES ( '00000000-0000-4000-8000-00000000aaaa', 'an earlier insert' );
          SELECT LAST_INSERT_ID() > 0;
          CALL create_buffer_component( $ALICE, '', 'Trisx', 'mM', '0-1', 0, '1 2', '3 4' );
          SELECT last_insertID();
          SELECT description FROM bufferComponent WHERE bufferComponentID = last_insertID();" )
check "a new component after an unrelated insert: status, its ID, it" \
      "1 0 105 Trisx" "$( echo $out )"

out=$( q "CALL create_buffer_component( $ALICE, '', 'Second', 'mM', '', 0, '', '' );
          SELECT last_insertID();" )
check "the next one" "0 106" "$( echo $out )"

out=$( q "CALL create_buffer_component( '00000000-0000-4000-8000-000000000902', 'wrong',
                                        '', 'Bad', 'mM', '', 0, '', '' );
          SELECT last_insertID();" )
check "refused: no ID" "104 0" "$( echo $out )"

out=$( q "INSERT INTO buffer ( bufferID, bufferGUID, description )
            VALUES ( 9601, '00000000-0000-4000-8000-000000009601', 'smoke buffer' );
          INSERT INTO bufferPerson ( bufferID, personID ) VALUES ( 9601, 902 );
          -- verify_buffer_permission() matches bufferPerson against the
          -- @US3_ID of the last login on the connection, before it logs
          -- the caller in; log in first, as UltraScan3 does on connecting
          SET @status = verify_user( $ALICE );
          CALL add_buffer_component( $ALICE, 9601, 105, 10 );
          SELECT last_insertID();" )
check "add_buffer_component reports no ID" "0 0" "$( echo $out )"

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
