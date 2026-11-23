#!/usr/bin/env bash
#
# tests/catalog_mutations.sh - check that catalog_smoke.sh catches broken
# catalog procedures
#
# Each mutation below is a small, plausible mistake in us3_catalog_procs.sql
# -- two columns swapped, a UTC conversion or an ORDER BY dropped, a blob
# hashed or not hashed, the old noise semantics, the "magic" experiment 1.
# For each one this writes a broken copy of the file, runs catalog_smoke.sh
# with that copy loaded over the real one (SMOKE_CATALOG), and expects the
# smoke test to FAIL.  A mutation the smoke test passes is a hole in it.
#
# Usage, from anywhere, with MYSQL (and SMOKE_DB) as for catalog_smoke.sh:
#
#   MYSQL="mysql --defaults-extra-file=$HOME/smoke.cnf" tests/catalog_mutations.sh [name...]
#
# With names, only those mutations run.  Each run of the smoke test takes
# a few seconds.  Exit status is 0 when every mutation was caught, 1 when
# any survived, and 2 when a mutation no longer applies to the file (the
# procedures changed; update the mutation) or the database could not be
# set up.

set -u

here=$( cd "$( dirname "$0" )" && pwd )
root=$( dirname "$here" )
procs="$root/us3_catalog_procs.sql"

tmp=$( mktemp -d )
trap 'rm -rf "$tmp"' EXIT

# name <TAB> perl substitution, applied to the whole file at once
mutations=$( cat <<'EOF'
summary-swap-runID-type	s/e\.runID,(\s+)e\.type,/e.type,$1e.runID,/
summary-no-utc	s/timestamp2UTC\( e\.dateUpdated \)/e.dateUpdated/
summary-no-order	s/ORDER BY e\.runID;/;/
summary-noise-by-edit	s/AND    m2\.editedDataID = d3\.editedDataID/AND    n.editedDataID  = d3.editedDataID/
raw-swap-label-filename	s/SELECT   rawDataID, rawDataGUID, label, filename,/SELECT   rawDataID, rawDataGUID, filename, label,/
raw-no-order	s/ORDER BY filename;/;/
edit-null-checksum	s/MD5\( d\.data \) AS checksum/NULL AS checksum/
model-swap-variance-meniscus	s/m\.variance, m\.meniscus/m.meniscus, m.variance/
model-no-order	s/ORDER BY m\.modelID DESC;/;/
noise-no-utc	s/timestamp2UTC\( n\.timeEntered \)/n.timeEntered/
noise-no-order	s/ORDER BY n\.timeEntered DESC;/;/
noise-by-edit	s/(JOIN model      m   ON n\.modelID      = m\.modelID\s+JOIN editedData d   ON )m\.editedDataID/$1n.editedDataID/
raw-by-person-hashed	s/NULL AS checksum, NULL AS size(\s+FROM     rawData r)/MD5( r.data ) AS checksum, LENGTH( r.data ) AS size$1/
edit-by-person-hashed	s/NULL AS checksum, NULL AS size(\s+FROM     editedData d)/MD5( d.data ) AS checksum, LENGTH( d.data ) AS size$1/
magic-experiment-1	s/verify_catalog_experiment\( p_experimentID \)/verify_experiment_permission( p_personGUID, p_password, p_experimentID )/g
EOF
)

caught=0 survived=0 broken=0

while IFS=$'\t' read -r name subst; do
   [ -z "$name" ] && continue
   if [ $# -gt 0 ] && ! printf '%s\n' "$@" | grep -qx "$name"; then
      continue
   fi

   copy="$tmp/$name.sql"
   # The substitution's own count, so a pattern that no longer matches
   # anything is reported rather than "caught"
   SUBST="$subst" COUNT="$tmp/count" perl -0777 -ne '
      my $n = eval "\$_ =~ $ENV{SUBST}";
      die $@ if $@;
      open( my $fh, ">", $ENV{COUNT} ) or die;
      print $fh ( $n || 0 ), "\n";
      print;' "$procs" > "$copy" || { echo "BROKEN   $name: bad substitution"; broken=$(( broken + 1 )); continue; }

   if [ "$( cat "$tmp/count" )" = 0 ] || cmp -s "$procs" "$copy"; then
      echo "BROKEN   $name: the mutation no longer applies to us3_catalog_procs.sql"
      broken=$(( broken + 1 ))
      continue
   fi

   SMOKE_CATALOG="$copy" "$here/catalog_smoke.sh" > "$tmp/$name.log" 2>&1 < /dev/null
   status=$?

   case $status in
      1) echo "caught   $name ($( grep -c '^FAIL' "$tmp/$name.log" ) checks failed)"
         caught=$(( caught + 1 )) ;;
      0) echo "SURVIVED $name: the smoke test passed with this mistake in place"
         survived=$(( survived + 1 )) ;;
      *) echo "BROKEN   $name: the smoke test could not run (exit $status):"
         sed 's/^/   /' "$tmp/$name.log" | tail -5
         broken=$(( broken + 1 )) ;;
   esac
done <<< "$mutations"

echo "== $caught caught, $survived survived, $broken broken"

[ "$broken" -gt 0 ] && exit 2
[ "$survived" -eq 0 ]
