#!/usr/bin/env bash
#
# tests/catalog_mutations.sh - check that catalog_smoke.sh and
# write_procs_test.sh catch broken procedures
#
# Each mutation below is a small, plausible mistake in one of the procedure
# files -- in us3_catalog_procs.sql two columns swapped, a UTC conversion or
# an ORDER BY dropped, a blob hashed or not hashed, the old noise
# semantics, the "magic" experiment 1; in delete_editedData,
# create_buffer_component and add_buffer_component a permission, GMP or
# ownership check dropped, the GMP links read before the row locks (a
# snapshot taken before the call waited), the GMP rule loosened (2DSA_MC
# ignored, a substring match, a fraction rounded, a comma-separated string
# taken as a list) or failing on 1e400, the edit's models read from a
# stale snapshot, the savepoint logic or the deadlock report broken, the
# locking read of the highest component ID back, the retries gone, a
# stale ID reported; in the autoflow procedures that insert a row with
# the caller's key, a stale ID reported, or one for a record that was not
# copied; in clear_experiment_fields and set_rotor_calibration_date a
# permission or not-found check dropped, the wrong field cleared, '' or
# NOW() stored instead of NULL or the date given, the range check, the
# form check, the invalid-date status or the NOT NULL column guard gone;
# the version marker wrong, or left behind by a failed load.
# For each one this writes a broken copy of the file, runs the test that
# covers it with that copy loaded over the real one -- catalog_smoke.sh
# (SMOKE_CATALOG) for us3_catalog_procs.sql, write_procs_test.sh
# (WRITE_OVERRIDE) for the others -- and expects the test to FAIL.  A
# mutation the test passes is a hole in it.
#
# Usage, from anywhere, with MYSQL (and SMOKE_DB, WRITE_DB) as for the
# tests:
#
#   MYSQL="mysql --defaults-extra-file=$HOME/smoke.cnf" tests/catalog_mutations.sh [name...]
#
# With names, only those mutations run.  A run of the smoke test takes a
# few seconds, one of write_procs_test.sh ten or so.  Exit status is 0
# when every mutation was caught, 1 when any survived, and 2 when a
# mutation no longer applies to its file (the procedures changed; update
# the mutation) or the database could not be set up.

set -u

here=$( cd "$( dirname "$0" )" && pwd )
root=$( dirname "$here" )

tmp=$( mktemp -d )
trap 'rm -rf "$tmp"' EXIT

# name <TAB> file <TAB> perl substitution, applied to the whole file at once
mutations=$( cat <<'EOF'
summary-swap-runID-type	us3_catalog_procs.sql	s/e\.runID,(\s+)e\.type,/e.type,$1e.runID,/
summary-no-utc	us3_catalog_procs.sql	s/timestamp2UTC\( e\.dateUpdated \)/e.dateUpdated/
summary-no-order	us3_catalog_procs.sql	s/ORDER BY e\.runID;/;/
summary-noise-by-edit	us3_catalog_procs.sql	s/AND    m2\.editedDataID = d3\.editedDataID/AND    n.editedDataID  = d3.editedDataID/
raw-swap-label-filename	us3_catalog_procs.sql	s/SELECT   rawDataID, rawDataGUID, label, filename,/SELECT   rawDataID, rawDataGUID, filename, label,/
raw-no-order	us3_catalog_procs.sql	s/ORDER BY filename;/;/
edit-null-checksum	us3_catalog_procs.sql	s/MD5\( d\.data \) AS checksum/NULL AS checksum/
model-swap-variance-meniscus	us3_catalog_procs.sql	s/m\.variance, m\.meniscus/m.meniscus, m.variance/
model-no-order	us3_catalog_procs.sql	s/ORDER BY m\.modelID DESC;/;/
noise-no-utc	us3_catalog_procs.sql	s/timestamp2UTC\( n\.timeEntered \)/n.timeEntered/
noise-no-order	us3_catalog_procs.sql	s/ORDER BY n\.timeEntered DESC;/;/
noise-by-edit	us3_catalog_procs.sql	s/(JOIN model      m   ON n\.modelID      = m\.modelID\s+JOIN editedData d   ON )m\.editedDataID/$1n.editedDataID/
raw-by-person-hashed	us3_catalog_procs.sql	s/NULL AS checksum, NULL AS size(\s+FROM     rawData r)/MD5( r.data ) AS checksum, LENGTH( r.data ) AS size$1/
edit-by-person-hashed	us3_catalog_procs.sql	s/NULL AS checksum, NULL AS size(\s+FROM     editedData d)/MD5( d.data ) AS checksum, LENGTH( d.data ) AS size$1/
magic-experiment-1	us3_catalog_procs.sql	s/verify_catalog_experiment\( p_experimentID \)/verify_experiment_permission( p_personGUID, p_password, p_experimentID )/g
del-magic-experiment-1	us3_expdata_procs.sql	s/verify_catalog_experiment\( l_experimentID \) != \@OK/verify_editData_permission( p_personGUID, p_password, p_editedDataID ) != \@OK/
del-no-edit1-refusal	us3_expdata_procs.sql	s/ELSEIF \( p_editedDataID = 1 \) THEN/ELSEIF ( p_editedDataID = -999 ) THEN/
del-no-verify-first	us3_expdata_procs.sql	s/SET l_status = verify_user\( p_personGUID, p_password \);/SET l_status = 0;/
del-no-gmp-check	us3_expdata_procs.sql	s/IF \( l_gmp_models IS NOT NULL OR l_gmp_noise IS NOT NULL \) THEN/IF ( 0 ) THEN/
del-gmp-id-as-text-only	us3_expdata_procs.sql	s/ELSEIF \( LEFT\( l_value, 1 \) IN/ELSEIF ( 0 AND LEFT( l_value, 1 ) IN/
del-gmp-no-pcsa	us3_expdata_procs.sql	s/'\$\.PCSA\[\*\]\.modelID'/'\$.PCSA_[*].modelID'/
del-gmp-any-key	us3_expdata_procs.sql	s/JSON_EXTRACT\( l_desc, '\$\."2DSA_IT"\[\*\]\.modelID',\s+'\$\."2DSA_MC"\[\*\]\.modelID',\s+'\$\.PCSA\[\*\]\.modelID' \)/JSON_EXTRACT( l_desc, '\$.*[*].modelID' )/
del-gmp-no-json-valid	us3_expdata_procs.sql	s/IF \( JSON_VALID\( l_desc \) \) THEN/IF ( 1 ) THEN/
del-gmp-invalid-ignored	us3_expdata_procs.sql	s/SET l_pos    = LOCATE\( 'modelID', l_raw \);/SET l_pos    = 0;/
del-gmp-substring	us3_expdata_procs.sql	s/LOCATE\( CONCAT\( ',', (l_id|(?:n\.)?modelID), ',' \), (l_candidates|l_gmp_ids) \) > 0/LOCATE( $1, $2 ) > 0/g
del-gmp-no-2dsa-mc	us3_expdata_procs.sql	s/\s+'\$\."2DSA_MC"\[\*\]\.modelID',//
del-gmp-fraction-rounded	us3_expdata_procs.sql	s/IF \( l_number = FLOOR\( l_number \) AND /IF ( 1 AND /
del-gmp-comma-in-string	us3_expdata_procs.sql	s/SET l_id = REPLACE\( JSON_UNQUOTE\( l_value \), ',', ' ' \);/SET l_id = JSON_UNQUOTE( l_value );/
del-gmp-huge-number-fails	us3_expdata_procs.sql	s/DECLARE CONTINUE HANDLER FOR 1292, 1264, 1367, 1690, SQLWARNING\n\s+SET l_number = NULL;//
del-gmp-candidates-snapshot	us3_expdata_procs.sql	s/(WHERE    editedDataID = p_editedDataID)\n        FOR UPDATE;/$1;/g
del-gmp-links-before-locks	us3_expdata_procs.sql	s/(    SET l_started = 1;\n)/$1    SELECT COUNT(*) INTO l_count_edits FROM autoflowModelsLink;\n/
del-no-foreign-check	us3_expdata_procs.sql	s/ELSEIF \( l_other_models IS NOT NULL OR l_other_noise IS NOT NULL \) THEN/ELSEIF ( 0 ) THEN/
del-no-foreign-models	us3_expdata_procs.sql	s/GROUP_CONCAT\( IF\( model_of_other_investigator\( modelID \) = 1, modelID, NULL \)/GROUP_CONCAT( IF( 0, modelID, NULL )/
del-foreign-for-admin-too	us3_expdata_procs.sql	s/IF \( \@USERLEVEL >= \@US3_ADMIN \) THEN\n    RETURN 0;/IF ( 0 ) THEN\n    RETURN 0;/
del-foreign-owner-snapshot	us3_expdata_procs.sql	s/\n  LOCK IN SHARE MODE;/;/
del-foreign-noise-snapshot	us3_expdata_procs.sql	s/(FROM       noise\n    WHERE      editedDataID = p_editedDataID)\n    FOR UPDATE;/$1;/
del-always-own-trx	us3_expdata_procs.sql	s/IF \( l_in_trx = 1 \) THEN\n      SAVEPOINT us3_delete_editedData_sp;/IF ( 0 ) THEN\n      SAVEPOINT us3_delete_editedData_sp;/
del-always-savepoint	us3_expdata_procs.sql	s/DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET l_in_trx = 0;/DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET l_in_trx = 1;/
del-no-noise-by-edit	us3_expdata_procs.sql	s/DELETE      FROM noise\n      WHERE       editedDataID = p_editedDataID;//
del-no-noise-by-model	us3_expdata_procs.sql	s/DELETE      noise\n      FROM        noise\n      JOIN        model ON \( model\.modelID = noise\.modelID \)\n      WHERE       model\.editedDataID = p_editedDataID;//
del-1451-as-error	us3_expdata_procs.sql	s/IN \( 1451, 1452 \)/IN ( 9999 )/
del-no-rollback-own	us3_expdata_procs.sql	s/      ELSE\n        ROLLBACK;\n\n      END IF;/      ELSE\n        COMMIT;\n\n      END IF;/
del-deadlock-as-status	us3_expdata_procs.sql	s/IF \( l_lost = 1 \) THEN/IF ( 0 ) THEN/
bc-for-update	us3_buffer_procs.sql	s/(SELECT     COALESCE\( MAX\( bufferComponentID \), 0 \) \+ 1\n    INTO       l_componentID\n    FROM       bufferComponent);/$1\n    FOR UPDATE;/
bc-count-plus-one	us3_buffer_procs.sql	s/SELECT     COALESCE\( MAX\( bufferComponentID \), 0 \) \+ 1\n    INTO/SELECT     COUNT(*) + 1\n    INTO/
bc-no-retry	us3_buffer_procs.sql	s/l_tries < 100/l_tries < 1/
bc-unbounded-retries	us3_buffer_procs.sql	s/l_tries < 100/l_tries < 1000/
bc-retry-same-id	us3_buffer_procs.sql	s/GREATEST\( l_componentID \+ 1,/GREATEST( l_componentID,/
bc-no-dup-status	us3_buffer_procs.sql	s/SET \@US3_LAST_ERRNO = \@INSERTDUP;(\n      SET \@US3_LAST_ERROR = 'MySQL: could not find)/SET \@US3_LAST_ERRNO = \@OK;$1/
bc-stale-id	us3_buffer_procs.sql	s/SET \@LAST_INSERT_ID = l_componentID;/SET \@LAST_INSERT_ID = LAST_INSERT_ID();/
bclink-stale-id	us3_buffer_procs.sql	s/(previous insert\n      )SET \@LAST_INSERT_ID = 0;/$1SET \@LAST_INSERT_ID = LAST_INSERT_ID();/
af-history-stale-id	us3_autoflow_procs.sql	s/(INSERT INTO autoflowHistory SELECT .*?)SET \@LAST_INSERT_ID = p_ID;/$1SET \@LAST_INSERT_ID = LAST_INSERT_ID();/s
af-history-no-rowcount	us3_autoflow_procs.sql	s/(INSERT INTO autoflowHistory SELECT .*?)IF \( ROW_COUNT\(\) > 0 \) THEN/$1IF ( 1 ) THEN/s
af-stages-stale-id	us3_autoflow_procs.sql	s/(INSERT INTO autoflowStages SET.*?)SET \@LAST_INSERT_ID = p_id;/$1SET \@LAST_INSERT_ID = LAST_INSERT_ID();/s
af-abde-stale-id	us3_autoflow_procs.sql	s/(INSERT INTO autoflowAnalysisABDEStages SET.*?)SET \@LAST_INSERT_ID = p_id;/$1SET \@LAST_INSERT_ID = LAST_INSERT_ID();/s
af-velmwl-stale-id	us3_autoflow_procs.sql	s/SET \@LAST_INSERT_ID = p_autoflowID;/SET \@LAST_INSERT_ID = LAST_INSERT_ID();/
af-esign-stale-id	us3_autoflow_procs.sql	s/(INSERT INTO autoflowGMPReportEsignHistory SELECT .*?)SET \@LAST_INSERT_ID = p_ID;/$1SET \@LAST_INSERT_ID = LAST_INSERT_ID();/s
af-esign-no-rowcount	us3_autoflow_procs.sql	s/(INSERT INTO autoflowGMPReportEsignHistory SELECT .*?)IF \( ROW_COUNT\(\) > 0 \) THEN/$1IF ( 1 ) THEN/s
version-wrong	us3_procedures.sql	s/RETURN\( 2 \);/RETURN( 1 );/
clear-magic-experiment-1	us3_exp_procs.sql	s/ELSEIF \( verify_catalog_experiment\( p_experimentID \) != \@OK \) THEN/ELSEIF ( verify_experiment_permission( p_personGUID, p_password, p_experimentID ) != \@OK ) THEN/
clear-no-permission	us3_exp_procs.sql	s/ELSEIF \( verify_catalog_experiment\( p_experimentID \) != \@OK \) THEN/ELSEIF ( 0 ) THEN/
clear-no-verify-first	us3_exp_procs.sql	s/(PROCEDURE clear_experiment_fields.*?)SET l_status = verify_user\( p_personGUID, p_password \);/$1SET l_status = 0;/s
clear-swapped-flags	us3_exp_procs.sql	s/IF\( COALESCE\( p_clearProtocol,  0 \) != 0, NULL, centrifugeProtocol \)/IF( COALESCE( p_clearRIProfile, 0 ) != 0, NULL, centrifugeProtocol )/
clear-empty-not-null	us3_exp_procs.sql	s/!= 0, NULL, RIProfile \)/!= 0, '', RIProfile )/
clear-both-always	us3_exp_procs.sql	s/IF\( COALESCE\( p_clearProtocol,  0 \) != 0, NULL, centrifugeProtocol \)/NULL/
caldate-any-user	us3_hardware_procs.sql	s/verify_userlevel\( p_personGUID, p_password, \@US3_ADMIN \) = \@OK \) THEN\n    SELECT COUNT\(\*\)\n    INTO   l_count/verify_userlevel( p_personGUID, p_password, \@US3_ANALYST ) = \@OK ) THEN\n    SELECT COUNT(*)\n    INTO   l_count/
caldate-no-not-found	us3_hardware_procs.sql	s/IF \( l_count = 0 \) THEN\n      SET \@US3_LAST_ERRNO = \@NO_CALIB;/IF ( 0 ) THEN\n      SET \@US3_LAST_ERRNO = \@NO_CALIB;/
caldate-now	us3_hardware_procs.sql	s/dateUpdated        = l_date/dateUpdated        = NOW()/
caldate-no-range-check	us3_hardware_procs.sql	s/COALESCE\( UNIX_TIMESTAMP\( l_date \), 0 \) NOT BETWEEN 1 AND 2147483647/0/
caldate-null-ignored	us3_hardware_procs.sql	s/dateUpdated        = l_date/dateUpdated        = COALESCE( l_date, dateUpdated )/
caldate-no-form-check	us3_hardware_procs.sql	s/IF \( p_dateUpdated REGEXP '[^']*' \) THEN/IF ( 1 ) THEN/
caldate-bad-date-ignored	us3_hardware_procs.sql	s/ELSEIF \( l_bad = 1 \) THEN/ELSEIF ( 0 ) THEN/
caldate-no-null-guard	us3_hardware_procs.sql	s/ELSEIF \( l_null_ok = 0 \) THEN/ELSEIF ( 0 ) THEN/
version-dropped-last	us3_procedures.sql	s/(DROP FUNCTION IF EXISTS us3_catalog_version\$\$)(.*?)(CREATE FUNCTION us3_catalog_version)/$2$1\n$3/s
EOF
)

caught=0 survived=0 broken=0 skipped=0

# Mutations that only a MariaDB server can show: MySQL's JSON refuses a
# number a double cannot hold (1e400), so the guard against it is never
# reached there
mariadb_only="del-gmp-huge-number-fails"
server=$( ${MYSQL:-mysql} -N -B -e "SELECT VERSION()" 2> /dev/null )

while IFS=$'\t' read -r name file subst; do
   [ -z "$name" ] && continue
   if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then
      continue
   fi

   if [[ "$server" != *MariaDB* ]] && printf '%s\n' $mariadb_only | grep -qx "$name"; then
      echo "skipped  $name: only a MariaDB server can show it"
      skipped=$(( skipped + 1 ))
      continue
   fi

   procs="$root/$file"
   copy="$tmp/$name/$file"
   mkdir -p "$tmp/$name"
   # The substitution's own count, so a pattern that no longer matches
   # anything is reported rather than "caught"
   SUBST="$subst" COUNT="$tmp/count" perl -0777 -ne '
      my $n = eval "\$_ =~ $ENV{SUBST}";
      die $@ if $@;
      open( my $fh, ">", $ENV{COUNT} ) or die;
      print $fh ( $n || 0 ), "\n";
      print;' "$procs" > "$copy" || { echo "BROKEN   $name: bad substitution"; broken=$(( broken + 1 )); continue; }

   if [ "$( cat "$tmp/count" )" = 0 ] || cmp -s "$procs" "$copy"; then
      echo "BROKEN   $name: the mutation no longer applies to $file"
      broken=$(( broken + 1 ))
      continue
   fi

   if [ "$file" = us3_catalog_procs.sql ]; then
      test=catalog_smoke.sh
      SMOKE_CATALOG="$copy" "$here/$test" > "$tmp/$name.log" 2>&1 < /dev/null
   else
      test=write_procs_test.sh
      WRITE_OVERRIDE="$copy" "$here/$test" > "$tmp/$name.log" 2>&1 < /dev/null
   fi
   status=$?

   case $status in
      1) echo "caught   $name ($( grep -c '^FAIL' "$tmp/$name.log" ) checks failed)"
         caught=$(( caught + 1 )) ;;
      0) echo "SURVIVED $name: $test passed with this mistake in place"
         survived=$(( survived + 1 )) ;;
      *) echo "BROKEN   $name: $test could not run (exit $status):"
         sed 's/^/   /' "$tmp/$name.log" | tail -5
         broken=$(( broken + 1 )) ;;
   esac
done <<< "$mutations"

echo "== $caught caught, $survived survived, $broken broken, $skipped skipped"

[ "$broken" -gt 0 ] && exit 2
[ "$survived" -eq 0 ]
