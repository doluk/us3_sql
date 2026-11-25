#!/usr/bin/env bash
#
# tests/write_procs_test.sh - live-server test for delete_editedData and the
# procedures that report a new record's ID
#
# Loads us3.sql, us3_procedures.sql and tests/catalog_fixture.sql into a
# scratch database, as catalog_smoke.sh does, and checks:
#
#   delete_editedData (us3_expdata_procs.sql)
#     - who may delete: an administrator or someone on the edit's
#       experiment, also for experiment 1; not the UNASSIGNED edit 1;
#     - what it will not take along: models and noise the GMP framework
#       refers to (autoflowModelsLink, also a row that is not valid JSON,
#       which must not make the call fail), for everybody, and another
#       investigator's models and noise, for anyone but an administrator --
#       also when they were committed after the caller's transaction took
#       its snapshot -- and a GMP link committed while the call waits for
#       a row lock (three sessions; in autocommit, after START
#       TRANSACTION and with autocommit off);
#     - deletes the edit, its models and their noise wherever it was
#       recorded (also noise computed from another experiment's edit),
#       and the noise recorded against the edit for a model of another
#       edit (a global fit);
#     - under READ COMMITTED, a model or noise record committed against
#       the edit after the call checked its records is not deleted: the
#       call fails on the edit's foreign key, deleting nothing;
#     - is all or nothing: when the edit cannot be deleted, nothing that
#       depends on it is deleted either, and the status says why --
#       standalone, inside a caller's open transaction (which it must
#       neither commit nor lose), with autocommit off, and in a read-only
#       transaction;
#     - a deadlock inside a caller's transaction is raised as error 1213,
#       not answered with a status (two sessions);
#     - 1000 models and noise records against 1000 GMP links, one model
#       against 20000 links of 9 models each, and an edit without models
#       against those links: within WRITE_PERF_LIMIT seconds (default 5);
#       an edit without models does not read the links at all (two
#       sessions: it does not wait for a locked one);
#     - a link that names a model only as a number with an exponent or a
#       string with a JSON escape still protects it;
#     - a GMP link after more link text than max_allowed_packet still
#       protects its model (only when the packet is at most
#       WRITE_PACKET_LIMIT MB, default 20, as the check writes that much);
#     - the GMP rule's edges: 2DSA_MC, a stage that is an object, IDs that
#       contain the model's ID or that it contains, a number that is not
#       whole, a string listing two IDs, and a number a double cannot
#       hold (1e400, valid JSON on MariaDB), which must not fail the call.
#
#   create_buffer_component (us3_buffer_procs.sql)
#     - takes a free ID when the table has a gap, and reports that ID (not
#       the connection's previous insert) through last_insertID();
#     - tries the next ID when one is taken, at most 100 times, then
#       answers @INSERTDUP (402) and reports no ID;
#     - inside a transaction whose snapshot is older than components
#       others committed since, still takes a free ID;
#     - two sessions, one creating components inside an open transaction,
#       the other at the same time: no deadlock, distinct IDs;
#     - reports 0 when it inserts nothing; add_buffer_component reports 0.
#
#   clear_experiment_fields (us3_exp_procs.sql)
#     - who may: an administrator or someone on the experiment, also for
#       experiment 1; strangers, bad logins and a missing experiment are
#       refused and change nothing;
#     - sets centrifugeProtocol and/or RIProfile to SQL NULL, each only
#       when asked; with nothing asked, changes nothing.
#
#   set_rotor_calibration_date (us3_hardware_procs.sql)
#     - administrators only; a missing calibration answers @NO_CALIB;
#     - stores the date given (in the connection's time zone), or NULL;
#       refuses with -1, changing nothing, a date a TIMESTAMP cannot hold
#       (also 1970-01-01 midnight east of UTC), a string that is not a
#       date of the form YYYY-MM-DD[ hh:mm:ss], and NULL where the column
#       is NOT NULL.
#
#   verify_model_permission() (us3_model_procs.sql), through
#   get_model_info and delete_model
#     - lets the model's owner in on a new connection, and nobody else
#       after the owner's login on the same connection.
#
#   us3_catalog_version() (us3_procedures.sql)
#     - answers 2, and is gone after a load of us3_procedures.sql that
#       failed half-way (with a client that stops at the error, as the
#       MySQL client does; the MariaDB client goes on).
#
#   the autoflow procedures that insert a row keyed by the caller's
#   autoflowID or the ID of the record they copy (us3_autoflow_procs.sql)
#     - report that key through last_insertID(), not the connection's
#       previous insert; 0 when refused, and 0 when there was no record to
#       copy.  On MySQL 8.0, where us3.sql cannot create the autoflow
#       *Stages tables, the test creates them, without the TEXT defaults.
#
# Usage and environment as for catalog_smoke.sh (MYSQL, KEEP_DB); the
# scratch database is WRITE_DB (default: us3_write_procs_test), DROPPED
# first and at the end.  WRITE_OVERRIDE names files to load after
# us3_procedures.sql, over the procedures it sources (catalog_mutations.sh
# uses it to load broken copies).  The account also needs the PROCESS
# privilege (the two-session checks read information_schema.INNODB_TRX).
# Exit status 0 when every check passes, 1 when any fails, 2 when the
# database could not be set up.

set -u

here=$( cd "$( dirname "$0" )" && pwd )
root=$( dirname "$here" )
MYSQL=${MYSQL:-mysql}
DB=${WRITE_DB:-us3_write_procs_test}
KEEP_DB=${KEEP_DB:-0}
OVERRIDE=${WRITE_OVERRIDE:-}

tmp=$( mktemp -d )
created=0
sessions=""

cleanup()
{
   local s pid
   for s in $sessions; do
      eval "exec {fd_$s}>&-" 2> /dev/null
      eval "pid=\$pid_$s"
      kill "$pid" 2> /dev/null
      wait "$pid" 2> /dev/null
   done
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

# Sessions that stay open between steps, for the checks that need two
# connections at once.  Each is a client reading statements from a FIFO;
# what it prints goes to $tmp/<name>.out, its errors to $tmp/<name>.err
# (it goes on after an error).
#
#   open_session <name>          and its connection ID in $cid_<name>
#   send <name> <sql>            send statements; does not wait for them
#   await <name> <tag> [<secs>]  send SELECT '<tag>' and wait until it is
#                                printed, that is until everything sent
#                                before it has run (default 30 s); 1 on
#                                timeout
#   lock_wait <name> [<secs>]    wait until the session waits for a row
#                                lock (default 30 s); 1 if it does not
#   between <name> <tag1> <tag2> what it printed between two tags
#   close_session <name>
open_session()
{
   mkfifo "$tmp/$1.in" || exit 2
   # Without the other sessions' FIFOs: a client holding one open would
   # keep that session from ever reading its end
   ( for s in $sessions; do eval "exec {fd_$s}>&-"; done
     exec $MYSQL -N -B -n --force "$DB" < "$tmp/$1.in" > "$tmp/$1.out" 2> "$tmp/$1.err" ) &
   eval "pid_$1=$!"
   eval "exec {fd_$1}> \"\$tmp/\$1.in\""
   sessions="$sessions $1"
   send "$1" "SELECT CONCAT( 'cid ', CONNECTION_ID() );"
   await "$1" "opened" 10 || { echo "ERROR: session $1 did not open"; exit 2; }
   eval "cid_$1=$( sed -n 's/^cid //p' "$tmp/$1.out" | head -1 )"
}

send()
{
   local fd
   eval "fd=\$fd_$1"
   printf '%s\n' "$2" >&"$fd"
}

await()
{
   local n=$(( ${3:-30} * 10 ))
   send "$1" "SELECT '$2';"
   while [ "$n" -gt 0 ]; do
      grep -qx "$2" "$tmp/$1.out" && return 0
      sleep 0.1; n=$(( n - 1 ))
   done
   return 1
}

lock_wait()
{
   local n=$(( ${2:-30} * 10 )) cid
   eval "cid=\$cid_$1"
   while [ "$n" -gt 0 ]; do
      [ "$( $MYSQL -N -B -e "SELECT COUNT(*) FROM information_schema.INNODB_TRX
                             WHERE trx_mysql_thread_id = $cid
                             AND   trx_state = 'LOCK WAIT'" 2> /dev/null )" = 1 ] && return 0
      sleep 0.1; n=$(( n - 1 ))
   done
   return 1
}

between()
{
   sed -n "/^$2\$/,/^$3\$/p" "$tmp/$1.out" | sed '1d;$d'
}

close_session()
{
   local pid
   eval "exec {fd_$1}>&-"
   eval "pid=\$pid_$1"
   wait "$pid" 2> /dev/null
   sessions=$( echo "$sessions" | sed "s/ $1\b//" )
   rm -f "$tmp/$1.in"
}

cd "$root" || exit 2
echo "== creating $DB"
setup $MYSQL -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\`"
created=1
$MYSQL "$DB" --force < us3.sql > /dev/null 2>&1
setup $MYSQL "$DB" -e "SOURCE us3_procedures.sql"
for f in $OVERRIDE; do
   setup $MYSQL "$DB" -e "SOURCE $f"
done
setup $MYSQL "$DB" -e "SOURCE $here/catalog_fixture.sql"

# MySQL 8.0 refuses us3.sql's autoflow*Stages tables (literal defaults on
# TEXT columns; see tests/README).  Create them as us3.sql has them, those
# defaults left out, where they are missing.
perl -0777 -ne '
   while ( /CREATE TABLE (autoflowStages|autoflowAnalysisABDEStages|autoflowAnalysisVelMwlStages) (\(.*?;)/sg ) {
      my ( $t, $body ) = ( $1, $2 );
      $body =~ s/\s+DEFAULT "[^"]*"//g;
      print "CREATE TABLE IF NOT EXISTS $t $body\n";
   }' us3.sql > "$tmp/stages.sql"
[ "$( grep -c '^CREATE TABLE' "$tmp/stages.sql" )" = 3 ] ||
   { echo "ERROR: setup failed: autoflow stages tables not found in us3.sql"; exit 2; }
setup $MYSQL "$DB" -e "SOURCE $tmp/stages.sql"

ADMIN="'00000000-0000-4000-8000-000000000901', 'adminpw'"
ALICE="'00000000-0000-4000-8000-000000000902', 'alicepw'"
BOB="'00000000-0000-4000-8000-000000000903', 'bobpw'"
CAROL="'00000000-0000-4000-8000-000000000904', 'carolpw'"

# The rows that depend on the fixture's edits, as one comparable line
STATE="SELECT CONCAT_WS( ' | ',
         ( SELECT GROUP_CONCAT( editedDataID ORDER BY editedDataID ) FROM editedData ),
         ( SELECT GROUP_CONCAT( modelID ORDER BY modelID ) FROM model ),
         ( SELECT GROUP_CONCAT( modelID ORDER BY modelID ) FROM modelPerson ),
         ( SELECT GROUP_CONCAT( noiseID ORDER BY noiseID ) FROM noise ) )"

FULL="1,9301,9302,9303,9304,9305 | 9401,9402,9403,9404,9405,9406,9407 | 9401,9402,9403,9405,9406,9407 | 9501,9502,9503,9504,9505,9507,9508,9509"

# del <caller> <editID> [<n>] : the status, last_errno() and the first n
# (default 60) characters of last_error(), on one line
del()
{
   echo $( q "CALL delete_editedData( $1, $2 );
              SELECT last_errno(), LEFT( last_error(), ${3:-60} )" )
}

FOREIGN="MySQL: the edit was not deleted: it would take along records of another investigator, which only an administrator may delete"
GMP="MySQL: the edit was not deleted: it would take along records the GMP framework refers to"

echo "== delete_editedData: who may delete"

check "fixture" "$FULL" "$( q "$STATE" )"

# Fixture: experiment 9101 is alice's and bob's, with edits 9301-9303;
# experiment 1 is bob's, with edit 9305; carol has no experiment
check "a stranger is refused" \
      "201 201 MySQL: you do not have permission to modify this experiment" \
      "$( del "$CAROL" 9301 )"
check "a stranger is refused experiment 1 too" \
      "201 201 MySQL: you do not have permission to modify this experiment" \
      "$( del "$CAROL" 9305 )"
check "... and so is another investigator of other experiments" \
      "201 201 MySQL: you do not have permission to modify this experiment" \
      "$( del "$ALICE" 9305 )"
check "UNASSIGNED edit 1 is refused" \
      "201 201 MySQL: the UNASSIGNED edit profile cannot be deleted" \
      "$( del "$ALICE" 1 )"
check "... also to an administrator" "201 201" "$( del "$ADMIN" 1 0 )"
check "an edit that does not exist" \
      "510 510 MySQL: no edit profile with that ID exists" \
      "$( del "$ALICE" 99999 )"
check "a bad password" "104 104" \
      "$( del "'00000000-0000-4000-8000-000000000902', 'x'" 9303 0 )"
check "after the refusals nothing changed" "$FULL" "$( q "$STATE" )"

echo "== delete_editedData: what it will not take along"

# 9303 has noise 9508 recorded against it for bob's model 9405 (a global
# fit); 9301 has bob's model 9403, with its noise 9502
check "alice: not bob's noise on her edit" \
      "201 201 $FOREIGN (noise of such models 9508)" \
      "$( del "$ALICE" 9303 250 )"
check "alice: not bob's model on her edit, nor its noise" \
      "201 201 $FOREIGN (models 9403; noise of such models 9502)" \
      "$( del "$ALICE" 9301 250 )"
check "after the refusals nothing changed" "$FULL" "$( q "$STATE" )"

# GMP: autoflowModelsLink names model 9405 (bob's, gamma's model, whose
# noise 9508 is recorded against 9303), as a string
q "INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
   VALUES ( 9701, '{\"2DSA_IT\":[{\"modelID\":\"9405\",\"modelGUID\":\"00000000-0000-4000-8000-000000009405\"}]}', 9801 )" > /dev/null
check "GMP noise: bob may not delete 9303" \
      "201 201 $GMP (noise of such models 9508)" \
      "$( del "$BOB" 9303 250 )"
check "GMP noise: nor may an administrator" "201 201" "$( del "$ADMIN" 9303 0 )"
check "GMP: the edit with the GMP model itself" \
      "201 201 $GMP (models 9405; noise of such models 9505,9508)" \
      "$( del "$ADMIN" 9304 250 )"

# ... and model 9404, edit 9303's own (nobody's), as a number, under PCSA
q "UPDATE autoflowModelsLink
   SET    modelsDesc = '{\"PCSA\":[{\"modelID\":9404}],\"2DSA_MC\":[]}'
   WHERE  autoflowAnalysisID = 9701" > /dev/null
check "GMP model of the edit: an administrator may not delete 9303" \
      "201 201 $GMP (models 9404; noise of such models 9503)" \
      "$( del "$ADMIN" 9303 250 )"

# ... and under 2DSA_MC
q "UPDATE autoflowModelsLink
   SET    modelsDesc = '{\"2DSA_MC\":[{\"modelID\":\"9404\"}]}'
   WHERE  autoflowAnalysisID = 9701" > /dev/null
check "GMP model under 2DSA_MC: an administrator may not delete 9303" \
      "201 201 $GMP (models 9404; noise of such models 9503)" \
      "$( del "$ADMIN" 9303 250 )"

# The same ID under a key UltraScan3 does not read, or in a stage that is
# an object rather than an array, or another ID -- one that contains it
# (94040), one it contains (404), a number that is not whole and would
# round to it (9403.6), a string that lists it and another of the edit's
# models (9405) -- is no GMP link (checked by the deletion further down)
q "UPDATE autoflowModelsLink
   SET    modelsDesc = '{\"2DSA\":[{\"modelID\":\"9404\"}],\"2DSA_IT\":{\"modelID\":\"9404\"},\"PCSA\":[{\"modelID\":\"94040\"},{\"modelID\":\"404\"},{\"modelID\":9403.6},{\"modelID\":\"9404,9405\"}]}'
   WHERE  autoflowAnalysisID = 9701" > /dev/null
check "after the refusals nothing changed" "$FULL" "$( q "$STATE" )"

# A modelsDesc that is not valid JSON: possible where the column has no
# CHECK, as in a table created on MariaDB before 10.4.3 (simulated by
# making it a LONGTEXT; on MySQL too).  JSON_CONTAINS on such a row failed
# (4038 in MariaDB, 3141 in MySQL), so one such row stopped every deletion.
# It cannot be read by key, so the digits after each "modelID" in it are
# protected: here 9404, of edit 9303 -- not 9303, which only a GUID holds
q "ALTER TABLE autoflowModelsLink MODIFY modelsDesc LONGTEXT NULL;
   INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
     VALUES ( 9702, '{\"2DSA\":[{\"modelGUID\":\"00000000-0000-4000-8000-000000009303\",\"modelID\": 9404', 9801 )" > /dev/null
check "a row that is not valid JSON is stored" "0" \
      "$( q "SELECT JSON_VALID( modelsDesc ) FROM autoflowModelsLink WHERE autoflowAnalysisID = 9702" )"
check "GMP, a row that is not JSON names model 9404: 9303 is refused" \
      "201 201 $GMP (models 9404; noise of such models 9503)" \
      "$( del "$BOB" 9303 250 )"

# The digits after "modelID", not those that merely contain the ID (or
# that it contains), nor a GUID's; such a row does not stop a deletion
# (rolled back again).  Nor does a number a double cannot hold: valid JSON
# on MariaDB (not on MySQL, whose JSON_VALID refuses it), it made every
# deletion there fail with error 1292.
q "UPDATE autoflowModelsLink
   SET    modelsDesc = '{\"PCSA\":[{\"modelID\":\"94040\",\"modelGUID\":\"00000000-0000-4000-8000-000000009404\"},{\"modelID\":\"940\"}'
   WHERE  autoflowAnalysisID = 9702;
   INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
     VALUES ( 9704, '{\"PCSA\":[{\"modelID\":1e400},{\"modelID\":-1e400}]}', 9801 )" > /dev/null
check "a row that is not JSON and names other models: bob may delete 9303" \
      "0 | 1,9301,9302,9304,9305" \
      "$( echo $( q "START TRANSACTION;
                     CALL delete_editedData( $BOB, 9303 );
                     SELECT '|', ( SELECT GROUP_CONCAT( editedDataID ORDER BY editedDataID ) FROM editedData );
                     ROLLBACK;" ) )"
check "after it nothing changed" "$FULL" "$( q "$STATE" )"
# The row stays, so every deletion below runs with it in the table

# A row whose text does not hold the model's ID may still name it: as a
# number with an exponent (9.404e3), or as a string spelled with JSON
# escapes ("\u0039\u0034\u0030\u0034").  The call does not look one by
# one at the IDs of rows whose text holds none of the IDs it checks, but
# must at these.  (The column is a LONGTEXT now, so the text stays as
# written, also on MySQL, whose JSON type would store 9404.0.)
for d in '{\"PCSA\":[{\"modelID\":9.404e3}]}' \
         '{\"PCSA\":[{\"modelID\":\"\\u0039\\u0034\\u0030\\u0034\"}]}'; do
   q "INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
        VALUES ( 9706, '$d', 9801 )" > /dev/null
   check "GMP model 9404 named as $( q "SELECT modelsDesc FROM autoflowModelsLink WHERE autoflowAnalysisID = 9706" ): 9303 is refused" \
         "201 201 $GMP (models 9404; noise of such models 9503)" \
         "$( del "$ADMIN" 9303 250 )"
   q "DELETE FROM autoflowModelsLink WHERE autoflowAnalysisID = 9706" > /dev/null
done

# Foreign noise committed after the caller's transaction took its snapshot:
# carol's model 9408 (on gamma's edit), with noise 9510 recorded against
# 9303.  Bob, on 9303's experiment, would otherwise be allowed to delete it.
open_session S
send S "START TRANSACTION WITH CONSISTENT SNAPSHOT;
        SELECT COUNT(*) FROM noise;"
await S s1 || echo "FAIL: snapshot session hangs"
q "INSERT INTO model ( modelID, editedDataID, modelGUID, description, xml )
     VALUES ( 9408, 9304, '00000000-0000-4000-8000-000000009408', 'carol.model', '<model/>' );
   INSERT INTO modelPerson ( modelID, personID ) VALUES ( 9408, 904 );
   INSERT INTO noise ( noiseID, noiseGUID, editedDataID, modelID, modelGUID,
                       noiseType, description, xml )
     VALUES ( 9510, '00000000-0000-4000-8000-000000009510', 9303, 9408,
              '00000000-0000-4000-8000-000000009408', 'ti_noise', 'carol.noise', '<noise/>' );" > /dev/null
send S "CALL delete_editedData( $BOB, 9303 );
        SELECT LEFT( last_error(), 250 );
        ROLLBACK;
        SELECT COUNT(*) FROM noise WHERE noiseID IN ( 9503, 9508, 9510 );"
await S s2 || echo "FAIL: snapshot session hangs"
check "noise committed after the caller's snapshot is checked as it is" \
      "201 $FOREIGN (noise of such models 9510) 3" \
      "$( echo $( between S s1 s2 ) )"
close_session S
q "DELETE FROM noise WHERE noiseID = 9510;
   DELETE FROM modelPerson WHERE modelID = 9408;
   DELETE FROM model WHERE modelID = 9408;" > /dev/null
check "... and nothing changed" "$FULL" "$( q "$STATE" )"

# The same for GMP: a link names model 9408 before the caller's snapshot
# is taken, the model and its noise 9510 against 9303 come after it.  The
# models whose links matter must be read as they are, too, or an
# administrator's call deletes that noise.
q "INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
     VALUES ( 9705, '{\"PCSA\":[{\"modelID\":\"9408\"}]}', 9801 )" > /dev/null
open_session S
send S "START TRANSACTION WITH CONSISTENT SNAPSHOT;
        SELECT COUNT(*) FROM noise;"
await S s1 || echo "FAIL: snapshot session hangs"
q "INSERT INTO model ( modelID, editedDataID, modelGUID, description, xml )
     VALUES ( 9408, 9304, '00000000-0000-4000-8000-000000009408', 'carol.model', '<model/>' );
   INSERT INTO modelPerson ( modelID, personID ) VALUES ( 9408, 904 );
   INSERT INTO noise ( noiseID, noiseGUID, editedDataID, modelID, modelGUID,
                       noiseType, description, xml )
     VALUES ( 9510, '00000000-0000-4000-8000-000000009510', 9303, 9408,
              '00000000-0000-4000-8000-000000009408', 'ti_noise', 'carol.noise', '<noise/>' );" > /dev/null
send S "CALL delete_editedData( $ADMIN, 9303 );
        SELECT LEFT( last_error(), 250 );
        ROLLBACK;
        SELECT COUNT(*) FROM noise WHERE noiseID IN ( 9503, 9508, 9510 );"
await S s2 || echo "FAIL: snapshot session hangs"
check "GMP noise committed after the caller's snapshot is checked as it is" \
      "201 $GMP (noise of such models 9510) 3" \
      "$( echo $( between S s1 s2 ) )"
close_session S
q "DELETE FROM noise WHERE noiseID = 9510;
   DELETE FROM modelPerson WHERE modelID = 9408;
   DELETE FROM model WHERE modelID = 9408;
   DELETE FROM autoflowModelsLink WHERE autoflowAnalysisID = 9705;" > /dev/null
check "... and nothing changed" "$FULL" "$( q "$STATE" )"

# A GMP link committed while the call waits for a row lock (three
# sessions).  A holds a lock on model 9402 of edit 9302; B, an
# administrator, deletes 9302 and waits for that lock; meanwhile a third
# connection records a GMP link naming 9402, and then A lets go.  B must
# read the links only once it has its locks, and as they are, and so
# refuse.  In autocommit the call's own transaction takes its snapshot
# after the wait; inside a transaction B opened (START TRANSACTION, or
# autocommit off, as UltraScan3 calls it), the call's first plain reads
# take it before, and a plain read of the links missed the new one.
# gmp_race <label> <statements B runs before the call>
gmp_race()
{
   open_session A
   open_session B
   send A "START TRANSACTION;
           SELECT modelID FROM model WHERE modelID = 9402 FOR UPDATE;"
   await A a1 || echo "FAIL: GMP race ($1): session A hangs"
   send B "$2
           CALL delete_editedData( $ADMIN, 9302 );
           SELECT LEFT( last_error(), 250 );
           SELECT COUNT(*) FROM model WHERE modelID = 9402;
           ROLLBACK;"
   if lock_wait B; then
      q "INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
           VALUES ( 9703, '{\"PCSA\":[{\"modelID\":\"9402\"}]}', 9801 )" > /dev/null
      send A "COMMIT;"
      await A a2 || echo "FAIL: GMP race ($1): session A hangs"
      await B b1 || echo "FAIL: GMP race ($1): session B hangs"
      check "a GMP link committed while the call waits for a row lock ($1): refused" \
            "201 $GMP (models 9402) 1" "$( echo $( between B opened b1 ) )"
   else
      check "GMP race ($1): session B waits for A's lock on model 9402" "waits" "does not"
   fi
   close_session A
   close_session B
   q "DELETE FROM autoflowModelsLink WHERE autoflowAnalysisID = 9703" > /dev/null
   check "... and nothing changed" "$FULL" "$( q "$STATE" )"
}
gmp_race "autocommit" ""
gmp_race "after START TRANSACTION" "START TRANSACTION;"
gmp_race "with autocommit off" "SET autocommit = 0;"

# READ COMMITTED takes no gap locks: a record committed against the edit
# after the call checked its records must not be deleted unchecked.  X
# holds a new report document of edit 9302, so that alice's call, its
# checks done, waits in its deletes; meanwhile another connection commits
# a record against 9302 that alice may not delete, and X lets go.  The
# call must leave that record, fail on the edit's foreign key and delete
# nothing.  (It deleted the newcomer, unchecked.)
# rc_race <label> <statements before the call> <the record, inserted>
#         <the record's count> <its removal>
rc_race()
{
   open_session X
   open_session A
   send X "START TRANSACTION;
           INSERT INTO reportDocument ( reportDocumentGUID, editedDataID )
             VALUES ( '00000000-0000-4000-8000-00000000c001', 9302 );"
   await X x1 || echo "FAIL: READ COMMITTED race ($1): session X hangs"
   send A "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED;
           $2
           CALL delete_editedData( $ALICE, 9302 );
           SELECT last_errno(), LOCATE( 'error 1451', last_error() ) > 0;
           $4;
           ROLLBACK;"
   if lock_wait A; then
      q "$3" > /dev/null
      send X "ROLLBACK;"
      await X x2 || echo "FAIL: READ COMMITTED race ($1): session X hangs"
      await A a1 || echo "FAIL: READ COMMITTED race ($1): session A hangs"
      check "READ COMMITTED, $1: refused on the foreign key, the newcomer stays" \
            "404 404 1 1" "$( echo $( between A opened a1 ) )"
   else
      check "READ COMMITTED race ($1): the call waits for X's report document" "waits" "does not"
   fi
   close_session X
   close_session A
   q "$5" > /dev/null
   check "... and nothing changed" "$FULL" "$( q "$STATE" )"
}
NEWNOISE="INSERT INTO noise ( noiseID, noiseGUID, editedDataID, modelID, modelGUID,
                             noiseType, description, xml )
            VALUES ( 9510, '00000000-0000-4000-8000-000000009510', 9302, 9405,
                     '00000000-0000-4000-8000-000000009405', 'ti_noise', 'bob.noise', '<noise/>' )"
NEWMODEL="INSERT INTO model ( modelID, editedDataID, modelGUID, description, xml )
            VALUES ( 9408, 9302, '00000000-0000-4000-8000-000000009408', 'carol.model', '<model/>' );
          INSERT INTO modelPerson ( modelID, personID ) VALUES ( 9408, 904 )"
rc_race "bob's noise, autocommit" "" "$NEWNOISE" \
        "SELECT COUNT(*) FROM noise WHERE noiseID = 9510" \
        "DELETE FROM noise WHERE noiseID = 9510"
rc_race "bob's noise, in a transaction" "START TRANSACTION;" "$NEWNOISE" \
        "SELECT COUNT(*) FROM noise WHERE noiseID = 9510" \
        "DELETE FROM noise WHERE noiseID = 9510"
rc_race "carol's model, autocommit" "" "$NEWMODEL" \
        "SELECT COUNT(*) FROM modelPerson WHERE modelID = 9408" \
        "DELETE FROM modelPerson WHERE modelID = 9408; DELETE FROM model WHERE modelID = 9408"
rc_race "carol's model, in a transaction" "START TRANSACTION;" "$NEWMODEL" \
        "SELECT COUNT(*) FROM modelPerson WHERE modelID = 9408" \
        "DELETE FROM modelPerson WHERE modelID = 9408; DELETE FROM model WHERE modelID = 9408"

echo "== delete_editedData: all or nothing"

# A table that refers to edit 9302, standing in for any reference the
# procedure does not clear, so that deleting 9302 fails at the very end
q "CREATE TABLE smoke_ref ( editedDataID INT NOT NULL,
     FOREIGN KEY ( editedDataID ) REFERENCES editedData ( editedDataID ) )
   ENGINE = InnoDB;
   INSERT INTO smoke_ref VALUES ( 9302 );
   CREATE TABLE smoke_outer ( id INT PRIMARY KEY ) ENGINE = InnoDB;" > /dev/null

check "a failing delete answers CONSTRAINT_FAILED" \
      "404 404 MySQL: the edit was not deleted, and nothi" "$( del "$ALICE" 9302 42 )"
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
          CALL delete_editedData( $BOB, 9303 );
          SELECT COUNT(*) FROM editedData WHERE editedDataID = 9303;
          ROLLBACK;" )
check "inside a transaction it deletes, and does not commit the caller's" \
      "0 0" "$( echo $out )"
check "... so the caller's rollback undoes both" "1 | $FULL" \
      "$( q "SELECT CONCAT( ( SELECT COUNT(*) FROM smoke_outer ), ' | ', ( $STATE ) )" )"

out=$( q "SET autocommit = 0;
          CALL delete_editedData( $BOB, 9303 );
          SELECT COUNT(*) FROM editedData WHERE editedDataID = 9303;
          ROLLBACK;" )
check "with autocommit off it deletes, and leaves the commit to the caller" \
      "0 0" "$( echo $out )"
check "... whose rollback undoes it" "$FULL" "$( q "$STATE" )"

out=$( q "START TRANSACTION READ ONLY;
          CALL delete_editedData( $BOB, 9303 );
          SELECT last_errno(), LOCATE( 'error 1792', last_error() ) > 0;
          COMMIT;" )
check "in a read-only transaction: ERROR, the server's error, and nothing deleted" \
      "-1 -1 1 | $FULL" "$( echo $out ) | $( q "$STATE" )"

# A deadlock inside a caller's transaction.  Session A locks edit 9305 and
# makes itself the bigger transaction; B (bob, whose experiment 1 is) starts
# a transaction and deletes 9305, deleting its model 9406 and noise 9507
# before it waits for A's lock on the edit; A then asks for model 9406.  The
# server rolls back the smaller transaction, B's, as a whole.
q "CREATE TABLE smoke_big ( id INT PRIMARY KEY ) ENGINE = InnoDB" > /dev/null
open_session A
open_session B
send A "START TRANSACTION;
        UPDATE editedData SET comment = 'held' WHERE editedDataID = 9305;
        INSERT INTO smoke_big SELECT bufferComponentID FROM bufferComponent;
        INSERT INTO smoke_big SELECT bufferComponentID + 1000 FROM bufferComponent;"
await A a1 || echo "FAIL: deadlock: session A hangs"
send B "START TRANSACTION;
        INSERT INTO smoke_outer VALUES ( 3 );
        CALL delete_editedData( $BOB, 9305 );
        SELECT 'b-called';"
if lock_wait B; then
   send A "SELECT modelID FROM model WHERE modelID = 9406 FOR UPDATE;"
   await A a2 || echo "FAIL: deadlock: session A hangs"
   send B "SELECT last_errno(), last_error();
           SELECT COUNT(*) FROM smoke_outer WHERE id = 3;
           ROLLBACK;"
   await B b2 || echo "FAIL: deadlock: session B hangs"
   send A "ROLLBACK;"
   await A a3
   msg=$( between B b-called b2 | head -1 )
   check "deadlock in a caller's transaction: raised as error 1213, no status" \
         "1 ''" \
         "$( grep -c '^ERROR 1213 (40001).*delete_editedData: deadlock' "$tmp/B.err" ) '$( between B opened b-called )'"
   check "... last_errno() is ERROR, and last_error() says once that the whole transaction is gone" \
         "-1 1 1" \
         "$( echo "$msg" | cut -f1 ) $( echo "$msg" | grep -o 'Deadlock found' | wc -l ) $( echo "$msg" | grep -o 'rolled back the whole transaction' | wc -l )"
   check "... and the caller's earlier work is gone with it" "0" \
         "$( between B b-called b2 | sed -n 2p )"
else
   check "deadlock: session B waits for A's lock on edit 9305" "waits" "does not"
fi
close_session A
close_session B
check "... and nothing was deleted" "$FULL" "$( q "$STATE" )"

echo "== delete_editedData: deleting"

# gamma's edit 9304, undone again: its model 9405 takes the global-fit
# noise 9508 along, although that was computed from alpha's edit 9303
check "bob deletes gamma's edit 9304 (rolled back again)" \
      "0 | 1,9301,9302,9303,9305 | 9401,9402,9403,9404,9406,9407 | 9401,9402,9403,9406,9407 | 9501,9502,9503,9504,9507,9509" \
      "$( echo $( q "START TRANSACTION;
                     CALL delete_editedData( $BOB, 9304 );
                     SELECT '|';
                     $STATE;
                     ROLLBACK;" ) )"
check "... and the rollback restored it" "$FULL" "$( q "$STATE" )"

# 9303: its model 9404 with noise 9503, and the global-fit noise 9508
# (recorded against 9303, fitted with gamma's model 9405) -- which made the
# old procedure fail half-way.  Bob is on 9303's experiment; 9404 is
# nobody's model, 9405 his own.
check "bob deletes edit 9303" "0" "$( q "CALL delete_editedData( $BOB, 9303 )" )"
check "... took its model, that model's noise and the global-fit noise" \
      "1,9301,9302,9304,9305 | 9401,9402,9403,9405,9406,9407 | 9401,9402,9403,9405,9406,9407 | 9501,9502,9504,9505,9507,9509" \
      "$( q "$STATE" )"

# 9301: models 9401 (alice) and 9403 (bob), their noise 9501, 9502 and
# 9504 (on edit 9302, fitted with 9401), and noise 9509 recorded against it
# for a model on the UNASSIGNED edit; that model, 9407, stays
check "an administrator deletes edit 9301" "0" "$( q "CALL delete_editedData( $ADMIN, 9301 )" )"
check "... took its models and all their noise, and the noise recorded against it" \
      "1,9302,9304,9305 | 9402,9405,9406,9407 | 9402,9405,9406,9407 | 9505,9507" \
      "$( q "$STATE" )"

check "bob deletes his edit 9305 in experiment 1" "0" \
      "$( q "CALL delete_editedData( $BOB, 9305 )" )"
check "... with its model 9406 and noise 9507" \
      "1,9302,9304 | 9402,9405,9407 | 9402,9405,9407 | 9505" \
      "$( q "$STATE" )"

echo "== delete_editedData: many models, many GMP links"

# Edit 9310 of alpha with 1000 models of alice's and a noise record for
# each, and 1000 autoflowModelsLink rows naming 9 other models each.  The
# GMP check used to search the whole table with JSON_CONTAINS for every
# model and noise record, under row locks: 18-25 s.  Now it reads the
# table once.  WRITE_PERF_LIMIT (seconds, default 5) is the limit for one
# call.  The row that is not JSON goes first, so that the old check gets as
# far as being slow.
LIMIT=${WRITE_PERF_LIMIT:-5}
q "DELETE FROM autoflowModelsLink WHERE autoflowAnalysisID = 9702" > /dev/null
# link <SQL expression> : an SQL expression for one {"modelID":...,"modelGUID":...}
link()
{
   echo "CONCAT( '{\"modelID\":\"', $1, '\",\"modelGUID\":\"00000000-0000-4000-8000-000000', $1, '\"}' )"
}
SEQ="( SELECT a.d + 10 * b.d + 100 * c.d AS i
       FROM   ( SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 ) a,
              ( SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 ) b,
              ( SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 ) c ) s"
setup $MYSQL "$DB" -e "
   SET FOREIGN_KEY_CHECKS = 0;
   INSERT INTO editedData ( editedDataID, rawDataID, editGUID, label, data, filename, comment )
     VALUES ( 9310, 9201, '00000000-0000-4000-8000-000000009310', 'smoke_many', 'EDIT-9310',
              'smoke_alpha.many.xml', '' );
   INSERT INTO model ( modelID, editedDataID, modelGUID, description, xml )
     SELECT 20000 + i, 9310, CONCAT( '00000000-0000-4000-8000-0000000', 20000 + i ),
            CONCAT( 'many.', i, '.model' ), '<model/>' FROM $SEQ;
   INSERT INTO modelPerson ( modelID, personID ) SELECT 20000 + i, 902 FROM $SEQ;
   INSERT INTO noise ( noiseID, noiseGUID, editedDataID, modelID, modelGUID,
                       noiseType, description, xml )
     SELECT 30000 + i, CONCAT( '00000000-0000-4000-8000-0000000', 30000 + i ), 9310, 20000 + i,
            CONCAT( '00000000-0000-4000-8000-0000000', 20000 + i ), 'ti_noise',
            CONCAT( 'many.', i, '.noise' ), '<noise/>' FROM $SEQ;
   INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
     SELECT 40000 + i,
            CONCAT( '{',
              '\"2DSA_IT\":[', $( link "100000 + 9 * i" ), ',', $( link "100001 + 9 * i" ), ',', $( link "100002 + 9 * i" ), '],',
              '\"2DSA_MC\":[', $( link "100003 + 9 * i" ), ',', $( link "100004 + 9 * i" ), ',', $( link "100005 + 9 * i" ), '],',
              '\"PCSA\":[',    $( link "100006 + 9 * i" ), ',', $( link "100007 + 9 * i" ), ',', $( link "100008 + 9 * i" ), ']}' ),
            9801
     FROM $SEQ;
   SET FOREIGN_KEY_CHECKS = 1;"
check "1000 models, 1000 noise records and 1000 links (valid JSON, 9 models each) loaded" \
      "1000 1000 1000 1000 9000" \
      "$( echo $( q "SELECT COUNT(*) FROM model WHERE editedDataID = 9310;
                     SELECT COUNT(*) FROM noise WHERE editedDataID = 9310;
                     SELECT COUNT(*), SUM( JSON_VALID( modelsDesc ) ),
                            SUM( JSON_LENGTH( JSON_EXTRACT( modelsDesc, '$.*[*].modelID' ) ) )
                     FROM autoflowModelsLink WHERE autoflowAnalysisID >= 40000" ) )"

# timed <sql> : its output, then the seconds the statements took
timed()
{
   q "SET @t0 = NOW( 6 ); $1; SELECT ROUND( TIMESTAMPDIFF( MICROSECOND, @t0, NOW( 6 ) ) / 1e6, 2 )"
}
fast() { awk -v t="$1" -v l="$LIMIT" 'BEGIN { print ( t + 0 <= l + 0 ) ? "fast" : "slow (" t " s)" }'; }

out=$( timed "START TRANSACTION;
              CALL delete_editedData( $ALICE, 9310 );
              SELECT COUNT(*), LEFT( last_error(), 200 ) FROM model WHERE editedDataID = 9310;
              ROLLBACK" )
echo "   delete_editedData, nothing protected: $( echo "$out" | tail -1 ) s"
check "nothing protected: deleted, within $LIMIT s" "0 0 fast" \
      "$( echo $( echo "$out" | sed '$d' ) $( fast "$( echo "$out" | tail -1 )" ) )"

# ... and one link naming model 20500; the edit also has model 2050,
# whose ID is part of that one's, and which is not protected
q "INSERT INTO model ( modelID, editedDataID, modelGUID, description, xml )
     VALUES ( 2050, 9310, '00000000-0000-4000-8000-000000002050', 'many.part.model', '<model/>' );
   INSERT INTO modelPerson ( modelID, personID ) VALUES ( 2050, 902 );
   INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
     VALUES ( 41000, '{\"PCSA\":[{\"modelID\":\"20500\"}]}', 9801 )" > /dev/null
out=$( timed "CALL delete_editedData( $ALICE, 9310 );
              SELECT LEFT( last_error(), 250 )" )
echo "   delete_editedData, one model protected: $( echo "$out" | tail -1 ) s"
check "one of them protected: refused, within $LIMIT s" \
      "201 $GMP (models 20500; noise of such models 30500) fast" \
      "$( echo $( echo "$out" | sed '$d' ) $( fast "$( echo "$out" | tail -1 )" ) )"

q "DELETE FROM autoflowModelsLink WHERE autoflowAnalysisID >= 40000" > /dev/null
check "... and without that link alice deletes it all" "0 | 0 0 0" \
      "$( echo $( q "CALL delete_editedData( $ALICE, 9310 );
                     SELECT '|';
                     SELECT COUNT(*) FROM model WHERE modelID BETWEEN 20000 AND 20999;
                     SELECT COUNT(*) FROM noise WHERE noiseID BETWEEN 30000 AND 30999;
                     SELECT COUNT(*) FROM editedData WHERE editedDataID = 9310" ) )"

# 20000 links, each naming nine models of other edits, and an edit with a
# single model.  Building the list of every GMP model ID with CONCAT took
# time quadratic in the number of links (15 s here, against 0.4 s with
# 1000 links); each ID is now looked up in the short list of the edit's
# own models.  The same limit applies.
SEQ5="( SELECT a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 10000 * f.d AS i
        FROM   ( SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 ) a,
               ( SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 ) b,
               ( SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 ) c,
               ( SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9 ) e,
               ( SELECT 0 AS d UNION ALL SELECT 1 ) f ) s"
setup $MYSQL "$DB" -e "
   SET FOREIGN_KEY_CHECKS = 0;
   INSERT INTO editedData ( editedDataID, rawDataID, editGUID, label, data, filename, comment )
     VALUES ( 9311, 9201, '00000000-0000-4000-8000-000000009311', 'smoke_one', 'EDIT-9311',
              'smoke_alpha.one.xml', '' );
   INSERT INTO model ( modelID, editedDataID, modelGUID, description, xml )
     VALUES ( 21000, 9311, '00000000-0000-4000-8000-000000021000', 'one.model', '<model/>' );
   INSERT INTO modelPerson ( modelID, personID ) VALUES ( 21000, 902 );
   INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
     SELECT 50000 + i,
            CONCAT( '{',
              '\"2DSA_IT\":[', $( link "200000 + 9 * i" ), ',', $( link "200001 + 9 * i" ), ',', $( link "200002 + 9 * i" ), '],',
              '\"2DSA_MC\":[', $( link "200003 + 9 * i" ), ',', $( link "200004 + 9 * i" ), ',', $( link "200005 + 9 * i" ), '],',
              '\"PCSA\":[',    $( link "200006 + 9 * i" ), ',', $( link "200007 + 9 * i" ), ',', $( link "200008 + 9 * i" ), ']}' ),
            9801
     FROM $SEQ5;
   SET FOREIGN_KEY_CHECKS = 1;"
check "an edit with one model, and 20000 links (9 models each) loaded" "1 20000 180000" \
      "$( echo $( q "SELECT COUNT(*) FROM model WHERE editedDataID = 9311;
                     SELECT COUNT(*), SUM( JSON_LENGTH( JSON_EXTRACT( modelsDesc, '$.*[*].modelID' ) ) )
                     FROM autoflowModelsLink WHERE autoflowAnalysisID >= 50000" ) )"

out=$( timed "START TRANSACTION;
              CALL delete_editedData( $ALICE, 9311 );
              SELECT COUNT(*), LEFT( last_error(), 200 ) FROM model WHERE editedDataID = 9311;
              ROLLBACK" )
echo "   delete_editedData, 20000 links, nothing protected: $( echo "$out" | tail -1 ) s"
check "20000 links, nothing protected: deleted, within $LIMIT s" "0 0 fast" \
      "$( echo $( echo "$out" | sed '$d' ) $( fast "$( echo "$out" | tail -1 )" ) )"

# An edit with no models and no noise: nothing a link could protect, so
# the call does not read the links at all.  Timed, and checked while
# another connection holds a lock on one of the links: the call must not
# wait for it (a lock wait of 1 s would fail it).
q "INSERT INTO editedData ( editedDataID, rawDataID, editGUID, label, data, filename, comment )
     VALUES ( 9312, 9201, '00000000-0000-4000-8000-000000009312', 'smoke_none', 'EDIT-9312',
              'smoke_alpha.none.xml', '' )" > /dev/null
out=$( timed "START TRANSACTION;
              CALL delete_editedData( $ALICE, 9312 );
              SELECT COUNT(*) FROM editedData WHERE editedDataID = 9312;
              ROLLBACK" )
echo "   delete_editedData, 20000 links, an edit without models: $( echo "$out" | tail -1 ) s"
check "20000 links, an edit without models: deleted, within $LIMIT s" "0 0 fast" \
      "$( echo $( echo "$out" | sed '$d' ) $( fast "$( echo "$out" | tail -1 )" ) )"
open_session L
send L "START TRANSACTION;
        SELECT COUNT(*) FROM autoflowModelsLink WHERE autoflowAnalysisID = 50000 FOR UPDATE;"
await L l1 || echo "FAIL: link lock session hangs"
check "... it does not read the links (no wait for a locked one)" "0 0" \
      "$( echo $( q "SET SESSION innodb_lock_wait_timeout = 1;
                     START TRANSACTION;
                     CALL delete_editedData( $ALICE, 9312 );
                     SELECT COUNT(*) FROM editedData WHERE editedDataID = 9312;
                     ROLLBACK" ) )"
send L "ROLLBACK;"
await L l2
close_session L

# The last link names the model
q "INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
     VALUES ( 79999, '{\"PCSA\":[{\"modelID\":\"21000\"}]}', 9801 )" > /dev/null
out=$( timed "CALL delete_editedData( $ALICE, 9311 );
              SELECT LEFT( last_error(), 250 )" )
echo "   delete_editedData, 20000 links, its model protected: $( echo "$out" | tail -1 ) s"
check "20000 links, the last protects its model: refused, within $LIMIT s" \
      "201 $GMP (models 21000) fast" \
      "$( echo $( echo "$out" | sed '$d' ) $( fast "$( echo "$out" | tail -1 )" ) )"
q "DELETE FROM autoflowModelsLink WHERE autoflowAnalysisID >= 50000" > /dev/null

# More link text than max_allowed_packet: the list of every GMP model ID
# came out NULL there (CONCAT gives NULL past the packet size), and the
# call deleted a GMP model.  Links whose modelID strings take 1 MB each,
# more of them than the packet holds, and then the one that names the
# model.  This writes as many MB as the packet size, so it runs only when
# that is at most WRITE_PACKET_LIMIT MB (default 20: MariaDB's default
# packet, not MySQL 8's 64 MB).
PACKET_MB=$( q "SELECT CEIL( @@max_allowed_packet / 1048576 )" )
if [ "$PACKET_MB" -le "${WRITE_PACKET_LIMIT:-20}" ]; then
   q "SET FOREIGN_KEY_CHECKS = 0;
      INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
        SELECT 60000 + i,
               CONCAT( '{\"PCSA\":[{\"modelID\":\"', REPEAT( '7', 1048576 ), '\"}]}' ), 9801
        FROM $SEQ WHERE i < $PACKET_MB + 2;
      INSERT INTO autoflowModelsLink ( autoflowAnalysisID, modelsDesc, autoflowID )
        VALUES ( 69999, '{\"PCSA\":[{\"modelID\":\"21000\"}]}', 9801 );
      SET FOREIGN_KEY_CHECKS = 1;" > /dev/null
   check "links of more than max_allowed_packet ($PACKET_MB MB) in all, then one naming its model: refused" \
         "201 $GMP (models 21000)" \
         "$( echo $( q "CALL delete_editedData( $ALICE, 9311 );
                        SELECT LEFT( last_error(), 250 )" ) )"
   q "DELETE FROM autoflowModelsLink WHERE autoflowAnalysisID >= 60000" > /dev/null
else
   echo "note: max_allowed_packet is $PACKET_MB MB, more than WRITE_PACKET_LIMIT;" \
        "the check with more link text than that is skipped"
fi
check "... and without those links alice deletes the edit" "0 0" \
      "$( echo $( q "CALL delete_editedData( $ALICE, 9311 );
                     SELECT COUNT(*) FROM model WHERE modelID = 21000" ) )"
check "... and the one without models" "0" "$( q "CALL delete_editedData( $ALICE, 9312 )" )"

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

# A trigger that makes the first @bc_fail inserts fail as duplicates, and
# counts the attempts
setup $MYSQL "$DB" -e "DELIMITER //
CREATE TRIGGER smoke_bc_dup BEFORE INSERT ON bufferComponent FOR EACH ROW
BEGIN
  SET @bc_tries = @bc_tries + 1;
  IF ( @bc_tries <= @bc_fail ) THEN
    SIGNAL SQLSTATE '23000' SET MYSQL_ERRNO = 1062, MESSAGE_TEXT = 'smoke duplicate';
  END IF;
END //"

out=$( q "SET @bc_tries = 0, @bc_fail = 2;
          CALL create_buffer_component( $ALICE, '', 'Third', 'mM', '', 0, '', '' );
          SELECT last_insertID(), @bc_tries;
          SELECT description FROM bufferComponent WHERE bufferComponentID = last_insertID();" )
check "two IDs taken: the one after, at the third attempt" "0 109 3 Third" "$( echo $out )"

out=$( q "INSERT INTO project ( projectGUID, description )
            VALUES ( '00000000-0000-4000-8000-00000000aaab', 'an earlier insert' );
          SET @bc_tries = 0, @bc_fail = 1000000;
          CALL create_buffer_component( $ALICE, '', 'Never', 'mM', '', 0, '', '' );
          SELECT last_insertID(), @bc_tries, last_errno(), last_error();
          SELECT COUNT(*) FROM bufferComponent WHERE description = 'Never';" )
check "every ID taken: INSERTDUP after 100 attempts, no ID, nothing inserted" \
      "402 0 100 402 MySQL: could not find a free buffer component ID; try again 0" \
      "$( echo $out )"

setup $MYSQL "$DB" -e "DROP TRIGGER smoke_bc_dup"

# A transaction whose snapshot predates components committed since
open_session S
send S "START TRANSACTION WITH CONSISTENT SNAPSHOT;
        SELECT MAX( bufferComponentID ) FROM bufferComponent;"
await S s1 || echo "FAIL: snapshot session hangs"
q "INSERT INTO bufferComponent ( bufferComponentID, description )
     VALUES ( 110, 'other 1' ), ( 111, 'other 2' ), ( 112, 'other 3' )" > /dev/null
send S "CALL create_buffer_component( $ALICE, '', 'Stale', 'mM', '', 0, '', '' );
        SELECT last_insertID();
        COMMIT;"
await S s2 || echo "FAIL: snapshot session hangs"
check "inside a transaction with an older snapshot (highest 109): a free ID" \
      "109 0 113" "$( echo $( between S opened s1 ) $( between S s1 s2 ) )"
close_session S
check "... which is the one it inserted" "Stale" \
      "$( q "SELECT description FROM bufferComponent WHERE bufferComponentID = 113" )"

# Two sessions: A creates components inside an open transaction (as an
# import does) while B, in a transaction of its own, creates one.  B's
# first choice is A's uncommitted ID, so B waits for A; A goes on creating,
# then commits, and B takes the next free ID.  With a locking read of the
# highest ID (FOR UPDATE) the two deadlock instead.
open_session A
open_session B
send A "START TRANSACTION;
        CALL create_buffer_component( $ALICE, '', 'conc A1', 'mM', '', 0, '', '' );
        SELECT CONCAT( 'id ', last_insertID() );"
await A a1 || echo "FAIL: concurrent: session A hangs"
send B "START TRANSACTION;
        CALL create_buffer_component( $BOB, '', 'conc B1', 'mM', '', 0, '', '' );
        SELECT CONCAT( 'id ', last_insertID() );
        COMMIT;"
lock_wait B 5 || echo "note: session B did not wait for session A"
send A "CALL create_buffer_component( $ALICE, '', 'conc A2', 'mM', '', 0, '', '' );
        SELECT CONCAT( 'id ', last_insertID() );
        CALL create_buffer_component( $ALICE, '', 'conc A3', 'mM', '', 0, '', '' );
        SELECT CONCAT( 'id ', last_insertID() );
        COMMIT;"
await A a2 20 || echo "FAIL: concurrent: session A hangs"
await B b1 20 || echo "FAIL: concurrent: session B hangs"
check "concurrent creation: no errors (no deadlock)" "" \
      "$( cat "$tmp/A.err" "$tmp/B.err" | grep -v -i warning )"
check "... every call OK" "0 0 0 0" \
      "$( echo $( grep -hx '[0-9-]*' "$tmp/A.out" "$tmp/B.out" ) )"
check "... distinct IDs, each the one it inserted" \
      "114 conc A1,115 conc A2,116 conc A3,117 conc B1" \
      "$( q "SELECT GROUP_CONCAT( CONCAT( bufferComponentID, ' ', description )
                                  ORDER BY bufferComponentID )
             FROM bufferComponent WHERE description LIKE 'conc %'" )"
check "... and reported" "114 115 116 117" \
      "$( echo $( sed -n 's/^id //p' "$tmp/A.out" "$tmp/B.out" ) )"
close_session A
close_session B

out=$( q "INSERT INTO buffer ( bufferID, bufferGUID, description )
            VALUES ( 9601, '00000000-0000-4000-8000-000000009601', 'smoke buffer' );
          INSERT INTO bufferPerson ( bufferID, personID ) VALUES ( 9601, 902 );
          INSERT INTO project ( projectGUID, description )
            VALUES ( '00000000-0000-4000-8000-00000000aaac', 'an earlier insert' );
          -- verify_buffer_permission() matches bufferPerson against the
          -- @US3_ID of the last login on the connection, before it logs
          -- the caller in; log in first, as UltraScan3 does on connecting
          SET @status = verify_user( $ALICE );
          CALL add_buffer_component( $ALICE, 9601, 105, 10 );
          SELECT last_insertID(), LAST_INSERT_ID() > 0;" )
check "add_buffer_component reports no ID (not the earlier insert's)" "0 0 1" "$( echo $out )"

echo "== autoflow inserts"

# These insert a row whose key is not AUTO_INCREMENT -- the caller's
# autoflowID, or the ID of the record copied -- so LAST_INSERT_ID() would
# be the connection's previous insert into some other table.  Each call
# below follows such an insert (a project) in the same connection.
q "INSERT INTO autoflow ( ID, protName, status, corrRadii, expAborted, gmpRun,
                          devRecord, expType )
     VALUES ( 9701, 'smoke', 'LIVE_UPDATE', 'YES', 'NO', 'NO', 'NO', 'VELOCITY' );
   INSERT INTO autoflowGMPReportEsign ( ID, autoflowID, eSignStatusAll )
     VALUES ( 9711, 9701, 'NO' )" > /dev/null

# af <n> <procedure> <ID> : an unrelated insert, the call as alice, its
# ID; then the same call with a wrong password, and its ID
af()
{
   echo $( q "INSERT INTO project ( projectGUID, description )
                VALUES ( '00000000-0000-4000-8000-00000000b$1', 'an earlier insert' );
              CALL $2( $ALICE, $3 );
              SELECT last_insertID();
              CALL $2( '00000000-0000-4000-8000-000000000902', 'wrong', $3 );
              SELECT last_insertID();" )
}

check "new_autoflow_history_record: the copied record's ID; refused: none" \
      "0 9701 104 0" "$( af 001 new_autoflow_history_record 9701 )"
check "... and the copy is there" "smoke" \
      "$( q "SELECT protName FROM autoflowHistory WHERE ID = 9701" )"
check "... a record that does not exist: nothing copied, no ID" \
      "0 0 104 0" "$( af 002 new_autoflow_history_record 9799 )"
check "add_autoflow_stages_record: the autoflowID; refused: none" \
      "0 9701 104 0" "$( af 003 add_autoflow_stages_record 9701 )"
check "new_autoflowAnalyisABDEstages_record: the autoflowID; refused: none" \
      "0 9701 104 0" "$( af 004 new_autoflowAnalyisABDEstages_record 9701 )"
check "new_autoflowAnalyisVelMwlStages_record: the autoflowID; refused: none" \
      "0 9701 104 0" "$( af 005 new_autoflowAnalyisVelMwlStages_record 9701 )"
check "... the three stages rows are there" "1 1 1" \
      "$( echo $( q "SELECT COUNT(*) FROM autoflowStages WHERE autoflowID = 9701;
                     SELECT COUNT(*) FROM autoflowAnalysisABDEStages WHERE autoflowID = 9701;
                     SELECT COUNT(*) FROM autoflowAnalysisVelMwlStages WHERE autoflowID = 9701" ) )"
check "new_gmp_review_history_record: the copied record's ID; refused: none" \
      "0 9711 104 0" "$( af 006 new_gmp_review_history_record 9711 )"
check "... and the copy is there" "9701" \
      "$( q "SELECT autoflowID FROM autoflowGMPReportEsignHistory WHERE ID = 9711" )"
check "... a record that does not exist: nothing copied, no ID" \
      "0 0 104 0" "$( af 007 new_gmp_review_history_record 9799 )"

echo "== clear_experiment_fields"

# Fields of the experiments the calls may change, as one line
EXPF="SELECT GROUP_CONCAT( CONCAT_WS( ':', experimentID,
                                      IFNULL( centrifugeProtocol, 'NULL' ),
                                      IFNULL( RIProfile, 'NULL' ) )
                           ORDER BY experimentID )
      FROM experiment WHERE experimentID IN ( 1, 9101, 9103 )"
q "UPDATE experiment SET centrifugeProtocol = CONCAT( 'cp', experimentID ),
                         RIProfile          = CONCAT( 'ri', experimentID )
   WHERE  experimentID IN ( 1, 9101, 9103 )" > /dev/null
EXPF_FULL="1:cp1:ri1,9101:cp9101:ri9101,9103:cp9103:ri9103"

# cef <caller> <experimentID> <clearProtocol> <clearRIProfile> : the
# status, last_errno() and last_error(), on one line
cef()
{
   echo $( q "CALL clear_experiment_fields( $1, $2, $3, $4 );
              SELECT last_errno(), last_error()" )
}
NOMOD="MySQL: you do not have permission to modify this experiment"

check "fields set" "$EXPF_FULL" "$( q "$EXPF" )"
check "a stranger is refused" "201 201 $NOMOD" "$( cef "$CAROL" 9101 1 1 )"
check "... also for experiment 1" "201 201 $NOMOD" "$( cef "$CAROL" 1 1 1 )"
check "... and so is another investigator of other experiments" \
      "201 201 $NOMOD" "$( cef "$ALICE" 1 1 1 )"
check "a bad password" "104 104" \
      "$( echo $( q "CALL clear_experiment_fields( '00000000-0000-4000-8000-000000000902', 'x', 9101, 1, 1 );
                     SELECT last_errno()" ) )"
check "userlevel 1" "104" \
      "$( q "CALL clear_experiment_fields( '00000000-0000-4000-8000-000000000907', 'frankpw', 9101, 1, 1 )" )"
check "an experiment that does not exist" \
      "508 508 MySQL: the specified experiment does not exist" \
      "$( cef "$ADMIN" 99999 1 1 )"
check "after the refusals nothing changed" "$EXPF_FULL" "$( q "$EXPF" )"

check "nothing to clear (0, NULL): OK" "0 0" \
      "$( echo $( q "CALL clear_experiment_fields( $ALICE, 9101, 0, NULL ); SELECT last_errno()" ) )"
check "... and nothing changed" "$EXPF_FULL" "$( q "$EXPF" )"

check "the owner clears the protocol of 9101" "0 0" "$( cef "$ALICE" 9101 1 0 )"
check "... it is NULL, the RI profile stays" \
      "1:cp1:ri1,9101:NULL:ri9101,9103:cp9103:ri9103" "$( q "$EXPF" )"
check "the other investigator of 9101 clears its RI profile" "0 0" "$( cef "$BOB" 9101 0 1 )"
check "... both NULL now" \
      "1:cp1:ri1,9101:NULL:NULL,9103:cp9103:ri9103" "$( q "$EXPF" )"
check "bob clears both of his experiment 1" "0 0" "$( cef "$BOB" 1 1 1 )"
check "an administrator clears the RI profile of bob's 9103" "0 0" "$( cef "$ADMIN" 9103 0 1 )"
check "... the protocol stays" \
      "1:NULL:NULL,9101:NULL:NULL,9103:cp9103:NULL" "$( q "$EXPF" )"
check "... then both" "0 0" "$( cef "$ADMIN" 9103 1 1 )"
check "... all NULL; a SQL NULL, not ''" \
      "1:NULL:NULL,9101:NULL:NULL,9103:NULL:NULL 3" \
      "$( echo $( q "$EXPF; SELECT COUNT(*) FROM experiment
                          WHERE experimentID IN ( 1, 9101, 9103 )
                          AND centrifugeProtocol IS NULL AND RIProfile IS NULL" ) )"

echo "== set_rotor_calibration_date"

q "INSERT INTO rotorCalibration ( rotorCalibrationID, rotorID, rotorCalibrationGUID,
                                  label, dateUpdated, calibrationExperimentID )
     VALUES ( 9901, NULL, '00000000-0000-4000-8000-000000009901', 'smoke cal',
              '2020-01-02 03:04:05', -1 )" > /dev/null
CALDATE="SELECT IFNULL( dateUpdated, 'NULL' ) FROM rotorCalibration WHERE rotorCalibrationID = 9901"

# rcd <caller> <ID> <date> : the status, last_errno() and last_error()
rcd()
{
   echo $( q "CALL set_rotor_calibration_date( $1, $2, $3 );
              SELECT last_errno(), last_error()" )
}

check "an investigator is refused" "201 201 MySQL: Not permitted at that userlevel" \
      "$( rcd "$ALICE" 9901 "'2019-03-04 05:06:07'" )"
check "a bad password" "104 104" \
      "$( echo $( q "CALL set_rotor_calibration_date( '00000000-0000-4000-8000-000000000901', 'x', 9901, '2019-03-04 05:06:07' );
                     SELECT last_errno()" ) )"
check "a calibration that does not exist" \
      "519 519 MySQL: no rotor calibration with ID 99999 exists" \
      "$( rcd "$ADMIN" 99999 "'2019-03-04 05:06:07'" )"
# Checked by the procedure itself, so the answer is the same whatever the
# sql_mode the procedure was created in (without strict mode the server
# would store a zero date with a warning)
RANGE="MySQL: the calibration date was not set: 1960-01-01 00:00:00 is outside the range a TIMESTAMP can hold"
check "a date before 1970: refused" "-1 -1 $RANGE" \
      "$( rcd "$ADMIN" 9901 "'1960-01-01 00:00:00'" )"
check "a date after 2038: refused" "-1 -1 ${RANGE/1960-01-01/2040-01-01}" \
      "$( rcd "$ADMIN" 9901 "'2040-01-01 00:00:00'" )"
check "after the refusals nothing changed" "2020-01-02 03:04:05" "$( q "$CALDATE" )"

# Not a date: refused with the status, not with error 1292 while the
# argument is converted (the parameter is a string for that reason); also
# forms the two servers read differently (an offset, which MySQL applies
# and MariaDB refuses; fractions, which one rounds and the other cuts)
FORM="is not a date of the form YYYY-MM-DD hh:mm:ss"
check "a date that does not exist: refused" \
      "-1 -1 MySQL: the calibration date was not set: '2019-02-30 00:00:00' $FORM" \
      "$( rcd "$ADMIN" 9901 "'2019-02-30 00:00:00'" )"
check "not a date at all: refused" \
      "-1 -1 MySQL: the calibration date was not set: 'yesterday' $FORM" \
      "$( rcd "$ADMIN" 9901 "'yesterday'" )"
check "a time-zone offset: refused" "-1 -1" \
      "$( rcd "$ADMIN" 9901 "'2019-03-04 05:06:07+00:00'" | cut -d' ' -f1,2 )"
check "fractions of a second: refused" "-1 -1" \
      "$( rcd "$ADMIN" 9901 "'2019-03-04 05:06:07.6'" | cut -d' ' -f1,2 )"
check "an empty string: refused" "-1 -1" \
      "$( rcd "$ADMIN" 9901 "''" | cut -d' ' -f1,2 )"
# MariaDB's REGEXP lets $ match before a final newline
check "a trailing newline: refused" "-1 -1" \
      "$( rcd "$ADMIN" 9901 "CONCAT( '2019-03-04 05:06:07', CHAR( 10 ) )" | cut -d' ' -f1,2 )"
check "a date alone with a trailing newline: refused" "-1 -1" \
      "$( rcd "$ADMIN" 9901 "CONCAT( '2019-03-04', CHAR( 10 ) )" | cut -d' ' -f1,2 )"
# In a time zone east of UTC, midnight of 1970-01-01 is before the range
check "1970-01-01 00:00:00 an hour east of UTC: refused" \
      "-1 -1 MySQL: the calibration date was not set: 1970-01-01 00:00:00 is outside the range a TIMESTAMP can hold" \
      "$( echo $( q "SET time_zone = '+01:00';
                     CALL set_rotor_calibration_date( $ADMIN, 9901, '1970-01-01 00:00:00' );
                     SELECT last_errno(), last_error()" ) )"
check "after the refusals nothing changed" "2020-01-02 03:04:05" "$( q "$CALDATE" )"

check "an administrator sets the date" "0 0" \
      "$( rcd "$ADMIN" 9901 "'2019-03-04 05:06:07'" )"
check "... which is stored" "2019-03-04 05:06:07" "$( q "$CALDATE" )"
check "a date alone: midnight" "0 0 | 2019-03-05 00:00:00" \
      "$( echo $( q "CALL set_rotor_calibration_date( $ADMIN, 9901, '2019-03-05' );
                     SELECT last_errno(); SELECT '|'; $CALDATE" ) )"
# In the connection's time zone: given two hours east of UTC, read in UTC
check "in the connection's time zone" "0 0 | 2019-03-04 03:06:07" \
      "$( echo $( q "SET time_zone = '+02:00';
                     CALL set_rotor_calibration_date( $ADMIN, 9901, '2019-03-04 05:06:07' );
                     SELECT last_errno(); SELECT '|';
                     SET time_zone = '+00:00';
                     $CALDATE" ) )"

# A table whose column cannot hold NULL (a TIMESTAMP declared without
# NULL): NULL is refused, not turned into the time of the call (MySQL 5.7
# defaults) or error 1048
q "UPDATE rotorCalibration SET dateUpdated = '2001-01-01 00:00:00' WHERE dateUpdated IS NULL;
   ALTER TABLE rotorCalibration MODIFY dateUpdated TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP" > /dev/null
check "NULL when the column cannot hold it: refused, nothing changed" \
      "-1 -1 MySQL: the calibration date was not set: the column cannot hold NULL in this database | 2019-03-04 05:06:07" \
      "$( echo $( q "SET time_zone = '+00:00';
                     CALL set_rotor_calibration_date( $ADMIN, 9901, '2019-03-04 05:06:07' );
                     CALL set_rotor_calibration_date( $ADMIN, 9901, NULL );
                     SELECT last_errno(), last_error(); SELECT '|'; $CALDATE" ) | sed 's/^0 //' )"
q "ALTER TABLE rotorCalibration MODIFY dateUpdated TIMESTAMP NULL" > /dev/null
check "... and NULL" "0 | NULL" \
      "$( echo $( q "CALL set_rotor_calibration_date( $ADMIN, 9901, NULL ); SELECT '|'; $CALDATE" ) )"

echo "== verify_model_permission"

# It matched the model's modelPerson row against the @US3_ID of the last
# login on the connection, before logging the caller in: on a new
# connection (each q is one) the owner was refused, and after somebody
# else's login the caller got that person's models.  Left: alice's 9402
# and 9407, bob's 9405.
check "get_model_info: the owner, on a new connection" "0" \
      "$( q "CALL get_model_info( $ALICE, 9402 )" | head -1 )"
check "... another investigator is refused" "201" \
      "$( q "CALL get_model_info( $BOB, 9402 )" | head -1 )"
check "... also after the owner's login on the same connection" "201" \
      "$( q "SET @s = verify_user( $ALICE );
             CALL get_model_info( $BOB, 9402 )" | head -1 )"
check "delete_model: the owner, on a new connection (rolled back)" "0 0" \
      "$( echo $( q "START TRANSACTION;
                     CALL delete_model( $ALICE, 9407 );
                     SELECT COUNT(*) FROM model WHERE modelID = 9407;
                     ROLLBACK" ) )"
check "... another investigator is refused, also after the owner's login" "201 1" \
      "$( echo $( q "SET @s = verify_user( $BOB );
                     CALL delete_model( $ALICE, 9405 );
                     SELECT COUNT(*) FROM model WHERE modelID = 9405" ) )"

echo "== us3_catalog_version"

check "the version marker" "2" "$( q "SELECT us3_catalog_version()" )"

# Last, as it reloads the procedures: a load of us3_procedures.sql that
# stops half-way (here in its last sourced file) leaves no marker behind,
# not even the one an earlier complete load created
mkdir "$tmp/partial"
for f in us3_procedures.sql us3_*_procs.sql; do
   src="$root/$f"
   for o in $OVERRIDE; do [ "$( basename "$o" )" = "$f" ] && src=$o; done
   ln -s "$src" "$tmp/partial/$f"
done
rm "$tmp/partial/us3_refscan_procs.sql"
echo "SELECT no_such_column;" > "$tmp/partial/us3_refscan_procs.sql"
if ( cd "$tmp/partial" && $MYSQL "$DB" -e "SOURCE us3_procedures.sql" > /dev/null 2>&1 ); then
   # The MariaDB client (10.11) reports an error in a sourced file, goes
   # on with the next statement, and exits 0; the marker then says only
   # that the file was run to its end
   echo "note: this client went on after an error in a sourced file;" \
        "the check that a failed load leaves no marker is skipped"
else
   check "a load that failed half-way: no marker" "ERROR" \
         "$( q "SELECT us3_catalog_version()" | cut -c1-5 )"
   check "... and the client's error is 1305" "1" \
         "$( q "SELECT us3_catalog_version()" | grep -c ' 1305 ' )"
fi

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
